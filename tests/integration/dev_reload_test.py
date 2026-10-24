#!/usr/bin/env python3
"""Integration: scripts/dev.py rebuilds a real Goose Web program on edits and reloads the browser.

Usage: python3 tests/integration/dev_reload_test.py   (GOOSE, or goose on PATH, builds the program)

The test starts dev.py on a small program in a temporary directory, then edits it: a valid change
must restart the server and send `reload`; a broken change must send `error` with the compiler output
while the old server keeps answering; the fix must restart again. Finally SIGINT stops everything.
"""
from pathlib import Path
import os
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time

# This directory holds http.py (the HTTP integration tests), which would shadow the standard http
# package that urllib needs. Drop the script directory from the import path before importing urllib.
if sys.path and Path(sys.path[0] or ".").resolve() == Path(__file__).resolve().parent:
    sys.path.pop(0)
import urllib.request  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
DEV = ROOT / "scripts" / "dev.py"
BUILD_TIMEOUT = 300

PROGRAM = '''import goose_web from "{package}";
import std;
import os;

const VERSION = "{version}";

fn app(c: web::Ctx&) {{
    web::live_reload(c) {{
        c.routes() {{
            c.get("/") {{ c.html("<!doctype html><html><body><p>page</p></body></html>"); }};
            c.get("/version") {{ c.text(VERSION); }};
        }};
    }};
}}

fn main() {{
    let config, ok, error = web::config_from_args(args());
    if !ok {{ abort(error); }}
    let started = web::run(config) {{ c => app(c) }};
    if !started {{ abort("server failed"); }}
}}
'''


def free_port():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def get(port, path):
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{port}{path}", timeout=5) as response:
            return response.read().decode("utf-8", errors="replace")
    except Exception:
        return None


def wait_until(check, what, timeout):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if check():
            return
        time.sleep(0.2)
    raise AssertionError(f"timed out waiting for {what}")


class EventStream:
    """Reads /events on a background thread and keeps every (name, data) pair in order."""

    def __init__(self, port):
        self.events = []
        self.condition = threading.Condition()
        self.response = urllib.request.urlopen(f"http://127.0.0.1:{port}/events", timeout=None)
        self.thread = threading.Thread(target=self.read, daemon=True)
        self.thread.start()

    def read(self):
        name, data = "message", []
        try:
            for raw in self.response:
                line = raw.decode("utf-8").rstrip("\r\n")
                if line == "":
                    if data:
                        with self.condition:
                            self.events.append((name, "\n".join(data)))
                            self.condition.notify_all()
                    name, data = "message", []
                elif line.startswith("event: "):
                    name = line[len("event: "):]
                elif line.startswith("data: "):
                    data.append(line[len("data: "):])
        except Exception:
            pass

    def wait_for(self, name, after, timeout, contains=None):
        """The index and data of the first matching event at or after `after`."""
        deadline = time.monotonic() + timeout
        with self.condition:
            while True:
                for index in range(after, len(self.events)):
                    event_name, data = self.events[index]
                    if event_name == name and (contains is None or contains in data):
                        return index, data
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise AssertionError(f"timed out waiting for a {name} event")
                self.condition.wait(remaining)

    def count(self):
        with self.condition:
            return len(self.events)


def main():
    goose = os.environ.get("GOOSE", "goose")
    with tempfile.TemporaryDirectory(prefix="goose-dev-") as directory:
        project = Path(directory)
        server = project / "server.goose"
        # The program imports goose_web from this checkout; the path is relative to the project.
        package = os.path.relpath(ROOT, project).replace(os.sep, "/")
        server.write_text(PROGRAM.format(package=package, version="v1"))
        port, reload_port = free_port(), free_port()
        log_path = project / "dev.log"
        command = [sys.executable, str(DEV), str(server), "--port", str(port), "--reload-port", str(reload_port),
                   "--goose", goose]
        with open(log_path, "w") as log:
            dev = subprocess.Popen(command, cwd=str(project), stdout=log, stderr=subprocess.STDOUT)
        stream = None
        try:
            wait_until(lambda: get(port, "/version") == "v1", "the first build to serve v1", BUILD_TIMEOUT)
            stream = EventStream(reload_port)

            page = get(port, "/")
            script = f'<script src="http://127.0.0.1:{reload_port}/live.js"></script></body>'
            assert page is not None and script in page, f"live reload script not injected: {page!r}"
            live = get(reload_port, "/live.js")
            assert live is not None and "EventSource" in live, "live.js not served"
            print("ok: first build serves v1 and injects the reload script")

            # A valid edit restarts the server and reloads the browser.
            before = stream.count()
            server.write_text(PROGRAM.format(package=package, version="v2"))
            wait_until(lambda: get(port, "/version") == "v2", "the restarted server to serve v2", BUILD_TIMEOUT)
            stream.wait_for("reload", before, 30)
            print("ok: an edit restarts the server (v2) and sends reload")

            # A broken edit keeps the old server and sends the compiler output.
            before = stream.count()
            server.write_text("this is not goose\n")
            _, message = stream.wait_for("error", before, BUILD_TIMEOUT)
            assert message.strip(), "the error event carries the compiler output"
            assert get(port, "/version") == "v2", "the old server must keep running after a failed build"
            print("ok: a broken edit sends error and the old server keeps answering")

            # The fix restarts again.
            before = stream.count()
            server.write_text(PROGRAM.format(package=package, version="v3"))
            wait_until(lambda: get(port, "/version") == "v3", "the fixed server to serve v3", BUILD_TIMEOUT)
            stream.wait_for("reload", before, 30)
            print("ok: fixing the program restarts the server (v3) and sends reload")

            dev.send_signal(signal.SIGINT)
            dev.wait(timeout=60)
            assert dev.returncode == 0, f"dev.py exited with {dev.returncode}"
            assert get(port, "/version") is None, "the server must stop with dev.py"
            print("ok: Ctrl+C (SIGINT) stops the server and dev.py")
        finally:
            if stream is not None:
                stream.response.close()
            if dev.poll() is None:
                dev.kill()
                dev.wait()
            if os.environ.get("GOOSE_DEV_TEST_LOG"):
                print(log_path.read_text(), file=sys.stderr)
    print("Dev reload integration tests passed: restart on edit, error overlay keeps old server, fix restarts, SIGINT stops")


if __name__ == "__main__":
    main()
