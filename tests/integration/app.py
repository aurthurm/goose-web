#!/usr/bin/env python3
"""Live checks for the app DSL (c.routes, groups, params, 404/405) over real sockets."""
from pathlib import Path
import json
import socket
import subprocess
import sys
import time


def exchange(port, raw):
    with socket.create_connection(("127.0.0.1", port), timeout=3) as client:
        client.sendall(raw)
        chunks = []
        while chunk := client.recv(16384):
            chunks.append(chunk)
    wire = b"".join(chunks)
    headers, body = wire.split(b"\r\n\r\n", 1)
    status = int(headers.split(b" ", 2)[1])
    fields = dict(line.split(b": ", 1) for line in headers.split(b"\r\n")[1:])
    return status, fields, body


def test_app(executable):
    with socket.socket() as reservation:
        reservation.bind(("127.0.0.1", 0))
        port = reservation.getsockname()[1]
    process = subprocess.Popen([str(executable), str(port)], stdout=subprocess.DEVNULL)
    try:
        deadline = time.monotonic() + 3
        while True:
            if process.poll() is not None:
                raise AssertionError("app server exited during startup")
            try:
                with socket.create_connection(("127.0.0.1", port), timeout=0.1):
                    break
            except ConnectionRefusedError:
                if time.monotonic() > deadline:
                    raise
                time.sleep(0.02)

        status, fields, body = exchange(port, b"GET /health HTTP/1.1\r\nHost: x\r\n\r\n")
        assert status == 200 and body == b'{"status":"ok"}\n', body
        assert fields[b"Content-Type"] == b"application/json"

        status, _, body = exchange(port, b"GET /users/42 HTTP/1.1\r\nHost: x\r\n\r\n")
        assert status == 200 and body == b"user 42", (status, body)

        status, _, body = exchange(port, b"GET /users/new?x=1 HTTP/1.1\r\nHost: x\r\n\r\n")
        assert status == 200 and body == b"new user form", body

        status, _, body = exchange(port, b"GET /users/007 HTTP/1.1\r\nHost: x\r\n\r\n")
        assert status == 422 and json.loads(body)["error"]["code"] == "invalid_param", body

        status, _, body = exchange(port, b"GET /missing HTTP/1.1\r\nHost: x\r\n\r\n")
        assert status == 404 and json.loads(body)["error"]["code"] == "not_found", body

        status, fields, body = exchange(port, b"DELETE /users/42 HTTP/1.1\r\nHost: x\r\n\r\n")
        assert status == 405 and fields[b"Allow"] == b"GET, HEAD", fields
        assert json.loads(body)["error"]["code"] == "method_not_allowed", body

        status, fields, body = exchange(port, b"POST /users HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\n\r\n")
        assert status == 201 and body == b"created", (status, body)

        status, fields, body = exchange(port, b"HEAD /users/42 HTTP/1.1\r\nHost: x\r\n\r\n")
        assert status == 200 and body == b"" and int(fields[b"Content-Length"]) > 0, fields
        assert process.poll() is None
    finally:
        process.terminate()
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
    print("App socket tests passed: routes, groups, path params, 404, 405 with Allow, HEAD, status")


if __name__ == "__main__":
    executable = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[2] / "build/app"
    test_app(executable)
