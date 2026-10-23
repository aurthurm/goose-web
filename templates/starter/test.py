#!/usr/bin/env python3
"""End-to-end check for this project: build server.goose, start it on a free port, call every route, stop it.

Needs the Goose compiler (set GOOSE if it is not named goose on PATH) and a C compiler. Standard library only.
"""
from pathlib import Path
import json
import os
import signal
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parent
GOOSE = os.environ.get("GOOSE", "goose")


def free_port():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def call(port, method, path, body=None, raw=None):
    """Return (status, headers, text). A body is sent as JSON unless raw is given."""
    data = raw.encode() if raw is not None else (None if body is None else json.dumps(body).encode())
    headers = {"Content-Type": "application/json"} if data is not None else {}
    request = urllib.request.Request(f"http://127.0.0.1:{port}{path}", data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=5) as response:
            return response.status, response.headers, response.read().decode()
    except urllib.error.HTTPError as error:
        return error.code, error.headers, error.read().decode()


def expect(condition, message):
    if not condition:
        raise SystemExit(f"FAIL: {message}")
    print(f"ok   {message}")


def wait_ready(process, port):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise SystemExit(f"FAIL: server exited early:\n{process.stdout.read()}")
        try:
            if call(port, "GET", "/health")[0] == 200:
                return
        except OSError:
            time.sleep(0.05)
    raise SystemExit("FAIL: server did not answer /health within 10 seconds")


def error_code(text):
    return json.loads(text)["error"]["code"]


def main():
    build = ROOT / "build"
    build.mkdir(exist_ok=True)
    binary = build / "server"
    subprocess.run([GOOSE, "build", str(ROOT / "server.goose"), "-o", str(binary)], check=True, cwd=ROOT)

    port = free_port()
    process = subprocess.Popen([str(binary), "--port", str(port)], cwd=ROOT,
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    try:
        wait_ready(process, port)

        status, headers, text = call(port, "GET", "/health")
        expect(status == 200 and json.loads(text) == {"status": "ok"}, "GET /health answers ok JSON")
        expect(headers.get("X-Request-ID"), "responses carry X-Request-ID")
        expect(headers.get("X-Content-Type-Options") == "nosniff", "secure_headers adds nosniff")

        status, _, text = call(port, "GET", "/hello/Ada")
        expect(status == 200 and json.loads(text) == {"message": "Hello, Ada"}, "GET /hello/:name greets")
        status, _, text = call(port, "GET", "/hello/" + "a" * 57)
        expect(status == 422 and error_code(text) == "name_too_long", "long name is 422 name_too_long")

        status, _, text = call(port, "POST", "/notes", {"text": "first"})
        expect(status == 201 and json.loads(text) == {"text": "first", "pinned": False}, "POST /notes creates 201")
        status, _, text = call(port, "POST", "/notes", {"text": "second", "pinned": True})
        expect(status == 201 and json.loads(text)["pinned"] is True, "POST /notes keeps pinned")
        status, _, text = call(port, "POST", "/notes", raw="{not json")
        expect(status == 400 and error_code(text) == "invalid_json", "malformed JSON is 400 invalid_json")
        status, _, text = call(port, "POST", "/notes", {"text": "x", "extra": 1})
        expect(status == 422 and error_code(text) == "invalid_payload", "unknown key is 422 invalid_payload")

        status, _, text = call(port, "GET", "/notes")
        expect(status == 200 and [n["text"] for n in json.loads(text)] == ["first", "second"], "GET /notes lists both")
        status, _, text = call(port, "GET", "/notes?limit=1")
        expect(status == 200 and len(json.loads(text)) == 1, "GET /notes?limit=1 returns one note")
        status, _, text = call(port, "GET", "/notes?limit=zz")
        expect(status == 400 and error_code(text) == "invalid_query", "non-numeric limit is 400 invalid_query")
        status, _, text = call(port, "GET", "/notes?limit=99")
        expect(status == 422 and error_code(text) == "invalid_limit", "limit above 32 is 422 invalid_limit")

        status, headers, text = call(port, "GET", "/")
        expect(status == 200 and "text/html" in headers.get("Content-Type", ""), "GET / renders HTML")
        expect("2 note(s)" in text and "<li>first</li>" in text and "second (pinned)" in text,
               "the template lists notes and escapes them")

        status, _, text = call(port, "GET", "/openapi.json")
        expect(status == 200 and "/notes" in text and "/hello/{name}" in text, "/openapi.json documents the routes")
        status, _, text = call(port, "GET", "/docs")
        expect(status == 200 and "swagger-ui" in text, "/docs serves the API reference page")

        status, _, text = call(port, "GET", "/missing")
        expect(status == 404 and error_code(text) == "not_found", "unknown path is 404 not_found")
        status, headers, text = call(port, "DELETE", "/health")
        expect(status == 405 and "GET" in headers.get("Allow", ""), "wrong method is 405 with Allow")
    finally:
        process.send_signal(signal.SIGINT)
        try:
            output, _ = process.communicate(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            output, _ = process.communicate()
    print("server output:", output.strip() or "(none)")
    print("all starter checks passed")


if __name__ == "__main__":
    sys.exit(main())
