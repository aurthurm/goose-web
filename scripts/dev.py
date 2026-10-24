#!/usr/bin/env python3
"""Development server: rebuild and restart a Goose Web app when its files change, and reload the browser.

Usage:
  python3 scripts/dev.py SERVER.goose [--port N] [--reload-port N] [--watch DIR ...]
                         [--release] [--goose PATH] [--build-command CMD] [-- SERVER_ARGS ...]

SERVER.goose is the program's root file. It is built with `goose build` (debug checks on; --release
builds optimized), then run with `--port N` followed by SERVER_ARGS, so the program should read its
arguments with web::config_from_args. Files under the server's directory, the goose_web package
root (a local import in SERVER.goose) and each --watch DIR are watched for .goose, .html, .css, .js,
.build and other embedded asset files; build/, .git and hidden directories are skipped.

A successful build restarts the server (SIGTERM, then SIGKILL after a grace period) and tells
browsers to reload. A failed build keeps the running server, prints the compiler output and sends it
to the browser as an overlay; the next successful build clears it.

The browser side is web::live_reload middleware. dev.py sets GOOSE_WEB_LIVE_RELOAD to the URL of its
reload script (http://127.0.0.1:RELOAD_PORT/live.js), so the middleware injects it into HTML pages only
while the server runs under dev.py. The reload endpoint serves /live.js and an SSE stream at /events.

Standard library only. Linux uses inotify (through ctypes); other systems poll the file tree.
"""
from __future__ import annotations

import argparse
import ctypes
import ctypes.util
import json
import os
import queue
import re
import select
import shlex
import signal
import socket
import struct
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Callable, Iterable, List, Optional, Sequence, Set

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_PORT = 8080
DEBOUNCE_SECONDS = 0.15
MAX_DEBOUNCE_SECONDS = 1.0
IDLE_SECONDS = 0.5
POLL_INTERVAL_SECONDS = 0.25
GRACE_SECONDS = 5.0
READY_SECONDS = 15.0
HEARTBEAT_SECONDS = 15.0
WATCHED_SUFFIXES = (".goose", ".html", ".css", ".js", ".build", ".json", ".txt", ".svg",
                    ".png", ".jpg", ".jpeg", ".gif", ".ico", ".yaml", ".yml", ".sql", ".csv")
IGNORED_DIRECTORIES = frozenset({"build", "__pycache__", "node_modules"})
IMPORT_PATTERN = re.compile(r'^\s*import\s+goose_web\s+from\s+"([^"]+)"\s*;', re.MULTILINE)
LIVE_RELOAD_ENV = "GOOSE_WEB_LIVE_RELOAD"

# inotify constants (linux/inotify.h).
IN_MODIFY = 0x002
IN_ATTRIB = 0x004
IN_CLOSE_WRITE = 0x008
IN_MOVED_FROM = 0x040
IN_MOVED_TO = 0x080
IN_CREATE = 0x100
IN_DELETE = 0x200
IN_DELETE_SELF = 0x400
IN_MOVE_SELF = 0x800
IN_Q_OVERFLOW = 0x4000
IN_IGNORED = 0x8000
IN_ONLYDIR = 0x01000000
IN_ISDIR = 0x40000000
IN_NONBLOCK = 0x800
IN_CLOEXEC = 0x80000
INOTIFY_MASK = (IN_MODIFY | IN_ATTRIB | IN_CLOSE_WRITE | IN_MOVED_FROM | IN_MOVED_TO | IN_CREATE |
                IN_DELETE | IN_DELETE_SELF | IN_MOVE_SELF)

LIVE_RELOAD_JS = """// Goose Web live reload (scripts/dev.py): reloads the page after a successful build and
// shows the compiler output as an overlay after a failed one. EventSource reconnects by itself.
(function () {
  if (window.__gooseLiveReload) { return; }
  window.__gooseLiveReload = true;
  var origin = "";
  if (document.currentScript && document.currentScript.src) {
    origin = new URL(document.currentScript.src).origin;
  }
  var overlay = null;
  function showError(message) {
    if (!overlay) {
      overlay = document.createElement("div");
      overlay.setAttribute("role", "alert");
      overlay.style.cssText = "position:fixed;inset:0;z-index:2147483647;overflow:auto;margin:0;" +
        "padding:24px;background:rgba(32,0,0,0.94);color:#ffd7d7;font:14px/1.5 monospace;" +
        "white-space:pre-wrap";
      var title = document.createElement("div");
      title.style.cssText = "font-weight:bold;margin-bottom:12px;color:#fff";
      title.textContent = "Build failed. Fix the error and save; this page reloads after the next build.";
      overlay.appendChild(title);
      overlay.appendChild(document.createElement("pre"));
      document.body.appendChild(overlay);
    }
    overlay.querySelector("pre").textContent = message;
  }
  var source = new EventSource(origin + "/events");
  source.addEventListener("reload", function () { window.location.reload(); });
  source.addEventListener("error", function (event) {
    // Connection failures are plain Events without data; a build failure carries a JSON payload.
    if (typeof event.data !== "string" || event.data.length === 0) { return; }
    var payload = {};
    try { payload = JSON.parse(event.data); } catch (e) { payload = { message: event.data }; }
    showError(payload.message || "Build failed");
  });
})();
"""


def log(message: str) -> None:
    print(f"dev: {message}", file=sys.stderr, flush=True)


def ignored_directory(name: str) -> bool:
    return name.startswith(".") or name in IGNORED_DIRECTORIES


def watched_file(path: str) -> bool:
    name = os.path.basename(path)
    if name.startswith("#") or name.endswith("~"):
        return False
    return any(name.endswith(suffix) for suffix in WATCHED_SUFFIXES)


def iter_files(root: str) -> Iterable[str]:
    for directory, dirnames, filenames in os.walk(root):
        dirnames[:] = [name for name in dirnames if not ignored_directory(name)]
        for name in filenames:
            path = os.path.join(directory, name)
            if watched_file(path):
                yield path


class Debouncer:
    """Collects changed paths and releases them once no change arrived for `quiet` seconds (or `max_wait`)."""

    def __init__(self, quiet: float = DEBOUNCE_SECONDS, max_wait: float = MAX_DEBOUNCE_SECONDS,
                 clock: Callable[[], float] = time.monotonic):
        self.quiet = quiet
        self.max_wait = max_wait
        self.clock = clock
        self.paths: Set[str] = set()
        self.first = 0.0
        self.last = 0.0

    def add(self, paths: Iterable[str]) -> None:
        paths = set(paths)
        if not paths:
            return
        now = self.clock()
        if not self.paths:
            self.first = now
        self.paths |= paths
        self.last = now

    def due_at(self) -> float:
        return min(self.first + self.max_wait, self.last + self.quiet)

    def timeout(self, idle: float) -> float:
        """Seconds to wait for more changes: until the batch is due, or `idle` when nothing is pending."""
        if not self.paths:
            return idle
        return max(0.0, self.due_at() - self.clock())

    def due(self) -> Set[str]:
        """The pending batch once it is due (and cleared), else an empty set."""
        if self.paths and self.clock() >= self.due_at():
            batch, self.paths = self.paths, set()
            return batch
        return set()


class PollingWatcher:
    """Compares modification times and sizes; works everywhere, costs a tree walk per interval."""

    def __init__(self, roots: Sequence[str], accept: Callable[[str], bool] = watched_file,
                 interval: float = POLL_INTERVAL_SECONDS):
        self.roots = list(roots)
        self.accept = accept
        self.interval = interval
        self.snapshot = self._scan()

    def _scan(self):
        found = {}
        for root in self.roots:
            for path in iter_files(root):
                if not self.accept(path):
                    continue
                try:
                    status = os.stat(path)
                except OSError:
                    continue
                found[path] = (status.st_mtime_ns, status.st_size)
        return found

    def wait(self, timeout: float) -> Set[str]:
        end = time.monotonic() + timeout
        while True:
            time.sleep(min(self.interval, max(0.0, end - time.monotonic())))
            current = self._scan()
            changed = {path for path in set(current) | set(self.snapshot)
                       if current.get(path) != self.snapshot.get(path)}
            self.snapshot = current
            if changed or time.monotonic() >= end:
                return changed

    def close(self) -> None:
        pass


class InotifyWatcher:
    """Linux inotify through ctypes. Directories get one watch each; new directories are added as they appear."""

    def __init__(self, roots: Sequence[str], accept: Callable[[str], bool] = watched_file):
        libc = ctypes.CDLL(ctypes.util.find_library("c") or "libc.so.6", use_errno=True)
        self._add_watch = libc.inotify_add_watch
        self._add_watch.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_uint32]
        self._add_watch.restype = ctypes.c_int
        init = libc.inotify_init1
        init.argtypes = [ctypes.c_int]
        init.restype = ctypes.c_int
        self.fd = init(IN_NONBLOCK | IN_CLOEXEC)
        if self.fd < 0:
            raise OSError(ctypes.get_errno(), "inotify_init1 failed")
        self.roots = [os.path.abspath(root) for root in roots]
        self.accept = accept
        self.directories = {}
        for root in self.roots:
            self.add_tree(root)

    def _add_directory(self, directory: str) -> None:
        wd = self._add_watch(self.fd, os.fsencode(directory), INOTIFY_MASK | IN_ONLYDIR)
        if wd < 0:
            error = ctypes.get_errno()
            raise OSError(error, f"inotify_add_watch {directory}: {os.strerror(error)}")
        self.directories[wd] = directory

    def add_tree(self, root: str) -> List[str]:
        """Watches root and its subdirectories; returns the watched files found under it."""
        files = []
        for directory, dirnames, filenames in os.walk(root):
            dirnames[:] = [name for name in dirnames if not ignored_directory(name)]
            try:
                self._add_directory(directory)
            except OSError:
                if not os.path.isdir(directory):
                    continue
                raise
            files.extend(os.path.join(directory, name) for name in filenames
                         if self.accept(os.path.join(directory, name)))
        return files

    def wait(self, timeout: float) -> Set[str]:
        ready, _, _ = select.select([self.fd], [], [], timeout)
        if not ready:
            return set()
        changed: Set[str] = set()
        while True:
            try:
                buffer = os.read(self.fd, 65536)
            except BlockingIOError:
                break
            if not buffer:
                break
            offset = 0
            while offset < len(buffer):
                wd, mask, _cookie, length = struct.unpack_from("iIII", buffer, offset)
                name = os.fsdecode(buffer[offset + 16:offset + 16 + length].rstrip(b"\0"))
                offset += 16 + length
                if mask & IN_Q_OVERFLOW:
                    changed.update(self.roots)
                    continue
                if mask & IN_IGNORED:
                    self.directories.pop(wd, None)
                    continue
                base = self.directories.get(wd)
                if base is None:
                    continue
                path = os.path.join(base, name) if name else base
                if mask & IN_ISDIR:
                    if mask & (IN_CREATE | IN_MOVED_TO) and not ignored_directory(name):
                        changed.update(self.add_tree(path))
                    continue
                if name and self.accept(path):
                    changed.add(path)
        return changed

    def close(self) -> None:
        os.close(self.fd)


def make_watcher(roots: Sequence[str], accept: Callable[[str], bool] = watched_file,
                 force_polling: bool = False):
    """inotify where it is available, polling otherwise (and when inotify runs out of watches)."""
    if not force_polling and sys.platform.startswith("linux"):
        try:
            return InotifyWatcher(roots, accept)
        except (OSError, AttributeError) as error:
            log(f"inotify unavailable ({error}); polling for changes")
    return PollingWatcher(roots, accept)


def find_free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def port_open(port: int) -> bool:
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=0.2):
            return True
    except OSError:
        return False


def format_event(name: str, data: dict) -> bytes:
    return f"event: {name}\ndata: {json.dumps(data)}\n\n".encode("utf-8")


class LiveReloadHub:
    """Fans reload and error events out to the connected browsers. Remembers the last build error for new clients."""

    def __init__(self):
        self.lock = threading.Lock()
        self.clients: Set[queue.Queue] = set()
        self.last_error: Optional[str] = None

    def subscribe(self) -> "queue.Queue[bytes]":
        client: "queue.Queue[bytes]" = queue.Queue()
        with self.lock:
            self.clients.add(client)
            if self.last_error is not None:
                client.put(format_event("error", {"message": self.last_error}))
        return client

    def unsubscribe(self, client: "queue.Queue[bytes]") -> None:
        with self.lock:
            self.clients.discard(client)

    def _publish(self, name: str, data: dict) -> None:
        message = format_event(name, data)
        with self.lock:
            for client in self.clients:
                client.put(message)

    def reload(self) -> None:
        with self.lock:
            self.last_error = None
        self._publish("reload", {})

    def fail(self, message: str) -> None:
        with self.lock:
            self.last_error = message
        self._publish("error", {"message": message})


class ReloadRequestHandler(BaseHTTPRequestHandler):
    server_version = "goose-dev"

    def log_message(self, format, *args):  # keep the terminal for build and server output
        pass

    def _send(self, status: int, content_type: str, body: bytes) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/live.js":
            self._send(200, "application/javascript; charset=utf-8", LIVE_RELOAD_JS.encode("utf-8"))
        elif path == "/events":
            self._events()
        elif path == "/":
            self._send(200, "text/plain; charset=utf-8", b"goose dev: /live.js and /events\n")
        else:
            self._send(404, "text/plain; charset=utf-8", b"not found\n")

    def _events(self) -> None:
        hub: LiveReloadHub = self.server.hub
        client = hub.subscribe()
        try:
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream; charset=utf-8")
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            self.wfile.flush()
            while True:
                try:
                    message = client.get(timeout=HEARTBEAT_SECONDS)
                except queue.Empty:
                    message = b": ping\n\n"
                self.wfile.write(message)
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass
        finally:
            hub.unsubscribe(client)


class ReloadServer:
    def __init__(self, port: int, hub: LiveReloadHub):
        self.httpd = ThreadingHTTPServer(("127.0.0.1", port), ReloadRequestHandler)
        self.httpd.daemon_threads = True
        self.httpd.hub = hub
        self.thread = threading.Thread(target=self.httpd.serve_forever, name="goose-dev-reload", daemon=True)

    def start(self) -> None:
        self.thread.start()

    def stop(self) -> None:
        self.httpd.shutdown()
        self.httpd.server_close()


def imported_package_roots(source: Path) -> List[str]:
    """Local directories named by `import goose_web from "PATH";` in the root file, resolved from its directory."""
    roots = []
    for match in IMPORT_PATTERN.finditer(source.read_text(encoding="utf-8", errors="replace")):
        candidate = (source.parent / match.group(1)).resolve()
        if candidate.is_dir():
            roots.append(str(candidate))
    return roots


class DevServer:
    """Builds the program, runs it, and rebuilds it when watched files change."""

    def __init__(self, source: Path, port: int = DEFAULT_PORT, reload_port: Optional[int] = None,
                 watch: Sequence[str] = (), server_args: Sequence[str] = (), release: bool = False,
                 goose: str = "goose", build_command: Optional[Sequence[str]] = None,
                 force_polling: bool = False):
        self.source = source.resolve()
        self.server_dir = self.source.parent
        self.stem = self.source.stem
        self.port = port
        self.reload_port = reload_port if reload_port is not None else port + 1
        self.server_args = list(server_args)
        self.release = release
        self.goose = goose
        self.force_polling = force_polling
        self.build_template = list(build_command) if build_command else [
            goose, "build", "{source}", "-o", "{output}", "-O2" if release else "--debug"]
        self.out_dir = self.server_dir / "build" / "dev"
        self.roots = [str(self.server_dir)] + imported_package_roots(self.source)
        self.roots += [str(Path(root).resolve()) for root in watch]
        self.hub = LiveReloadHub()
        self.reload: Optional[ReloadServer] = None
        self.child: Optional[subprocess.Popen] = None
        self.binary: Optional[Path] = None
        self.generation = 0
        self.exit_reported = False

    @property
    def live_script_url(self) -> str:
        return f"http://127.0.0.1:{self.reload_port}/live.js"

    # build ----------------------------------------------------------------

    def build(self):
        """Returns (True, binary path) or (False, compiler output)."""
        self.generation += 1
        self.out_dir.mkdir(parents=True, exist_ok=True)
        output = self.out_dir / f"{self.stem}-{self.generation}"
        argv = [part.replace("{source}", str(self.source)).replace("{output}", str(output))
                for part in self.build_template]
        started = time.monotonic()
        try:
            result = subprocess.run(argv, cwd=str(self.server_dir), stdout=subprocess.PIPE,
                                    stderr=subprocess.STDOUT, timeout=900)
        except OSError as error:
            return False, f"could not run {argv[0]}: {error}"
        output_text = result.stdout.decode("utf-8", errors="replace")
        if result.returncode != 0:
            return False, output_text.rstrip() or f"build exited with status {result.returncode}"
        if not output.exists():
            text = output_text.rstrip() + "\n" if output_text.strip() else ""
            return False, text + f"build did not produce {output}"
        log(f"built {self.source.name} in {time.monotonic() - started:.1f} s")
        return True, str(output)

    # server ---------------------------------------------------------------

    def stop_server(self) -> None:
        child = self.child
        self.child = None
        if child is None or child.poll() is not None:
            return
        child.send_signal(signal.SIGTERM)
        try:
            child.wait(timeout=GRACE_SECONDS)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait()

    def start_server(self) -> str:
        """Starts the built program and waits until it listens. Returns an error message, or ''."""
        env = dict(os.environ)
        env[LIVE_RELOAD_ENV] = self.live_script_url
        argv = [str(self.binary), "--port", str(self.port)] + self.server_args
        self.child = subprocess.Popen(argv, cwd=str(self.server_dir), env=env)
        self.exit_reported = False
        deadline = time.monotonic() + READY_SECONDS
        while time.monotonic() < deadline:
            status = self.child.poll()
            if status is not None:
                self.child = None
                return f"the server exited with status {status} after starting"
            if port_open(self.port):
                return ""
            time.sleep(0.05)
        self.stop_server()
        return f"the server did not listen on port {self.port} within {READY_SECONDS:.0f} seconds"

    def restart(self, binary: Path) -> bool:
        """Replaces the running server with one built as binary. Returns True when it is listening."""
        previous = self.binary
        self.stop_server()
        self.binary = binary
        error = self.start_server()
        if error:
            self.hub.fail(error)
            log(error + "; fix the program and save to try again")
            return False
        if previous is not None and previous != binary:
            try:
                previous.unlink()
            except OSError:
                pass
        self.hub.reload()
        log(f"serving http://127.0.0.1:{self.port}/ (live reload on {self.reload_port})")
        return True

    # cycle ----------------------------------------------------------------

    def rebuild(self) -> bool:
        """Builds and, on success, restarts. A failed build keeps the running server and reports the output."""
        ok, result = self.build()
        if not ok:
            print(result, file=sys.stderr, flush=True)
            log("build failed; the running server is unchanged")
            self.hub.fail(result)
            return False
        return self.restart(Path(result))

    def check_child(self) -> None:
        if self.child is None or self.exit_reported or self.child.poll() is None:
            return
        self.exit_reported = True
        message = f"the server exited with status {self.child.returncode}; save a change to restart it"
        log(message)
        self.hub.fail(message)

    def relative(self, path: str) -> str:
        try:
            return os.path.relpath(path, self.server_dir)
        except ValueError:
            return path

    def run(self) -> int:
        try:
            self.reload = ReloadServer(self.reload_port, self.hub)
        except OSError as error:
            log(f"cannot listen for browsers on port {self.reload_port}: {error}; use --reload-port")
            return 1
        self.reload.start()
        log(f"watching {', '.join(self.roots)}")
        watcher = make_watcher(self.roots, watched_file, self.force_polling)
        debouncer = Debouncer()
        try:
            self.rebuild()
            while True:
                try:
                    changed = watcher.wait(debouncer.timeout(IDLE_SECONDS))
                except OSError as error:
                    # Events were lost while watches were set up; rebuild rather than guess.
                    log(f"watch error: {error}; rebuilding")
                    changed = set(self.roots)
                debouncer.add(changed)
                batch = debouncer.due()
                if batch:
                    names = ", ".join(sorted(self.relative(path) for path in batch))
                    log(f"changed: {names}")
                    self.rebuild()
                elif not debouncer.paths:
                    self.check_child()
        except KeyboardInterrupt:
            log("stopping")
            return 0
        finally:
            watcher.close()
            self.stop_server()
            self.reload.stop()


def parse_arguments(argv: Sequence[str]):
    if "--" in argv:
        split = list(argv).index("--")
        dev_args, server_args = list(argv[:split]), list(argv[split + 1:])
    else:
        dev_args, server_args = list(argv), []
    parser = argparse.ArgumentParser(description="Rebuild and restart a Goose Web program on change, and reload the browser.",
                                     epilog="Arguments after -- go to the program, after --port.")
    parser.add_argument("source", type=Path, help="the program's root .goose file")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT, help=f"port the program listens on (default {DEFAULT_PORT})")
    parser.add_argument("--reload-port", type=int, default=None, help="port of the live reload endpoint (default: --port + 1)")
    parser.add_argument("--watch", action="append", default=[], metavar="DIR", help="another directory to watch (repeatable)")
    parser.add_argument("--release", action="store_true", help="build optimized (-O2) instead of --debug")
    parser.add_argument("--goose", default=os.environ.get("GOOSE", "goose"), help="the goose compiler (default: $GOOSE or goose)")
    parser.add_argument("--build-command", default=None, metavar="CMD",
                        help="build with CMD instead of goose; {source} and {output} are replaced")
    parser.add_argument("--polling", action="store_true", help="poll for changes instead of using inotify")
    args = parser.parse_args(dev_args)
    if not args.source.is_file():
        parser.error(f"{args.source} is not a file")
    if not 1 <= args.port <= 65535:
        parser.error("--port must be from 1 to 65535")
    if args.reload_port is not None and args.reload_port == args.port:
        parser.error("--reload-port must differ from --port")
    return args, server_args


def main(argv: Sequence[str]) -> int:
    args, server_args = parse_arguments(argv)
    if args.reload_port is None:
        args.reload_port = args.port + 1
    build_command = shlex.split(args.build_command) if args.build_command else None
    server = DevServer(args.source, port=args.port, reload_port=args.reload_port, watch=args.watch,
                       server_args=server_args, release=args.release, goose=args.goose,
                       build_command=build_command, force_polling=args.polling)

    def interrupt(signum, frame):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, interrupt)
    return server.run()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
