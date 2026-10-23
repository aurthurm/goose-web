#!/usr/bin/env python3
"""Smoke test for examples/hello: health, a path-param JSON route, a typed POST, and the logger."""
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
    headers, body = b"".join(chunks).split(b"\r\n\r\n", 1)
    status = int(headers.split(b" ", 2)[1])
    fields = dict(line.split(b": ", 1) for line in headers.split(b"\r\n")[1:])
    return status, fields, body


def test_hello(executable):
    with socket.socket() as reservation:
        reservation.bind(("127.0.0.1", 0))
        port = reservation.getsockname()[1]
    process = subprocess.Popen([str(executable), str(port)], stdout=subprocess.DEVNULL)
    try:
        deadline = time.monotonic() + 3
        while True:
            assert process.poll() is None, "hello server exited during startup"
            try:
                with socket.create_connection(("127.0.0.1", port), timeout=0.1):
                    break
            except ConnectionRefusedError:
                if time.monotonic() > deadline:
                    raise
                time.sleep(0.02)

        status, fields, body = exchange(port, b"GET /health HTTP/1.1\r\nHost: x\r\n\r\n")
        assert status == 200 and body == b'{"status":"ok"}', body
        assert fields[b"Content-Type"] == b"application/json" and int(fields[b"X-Request-ID"]) > 0

        status, _, body = exchange(port, b"GET /hello/Ada HTTP/1.1\r\nHost: x\r\n\r\n")
        assert status == 200 and body == b'{"message":"Hello, Ada"}', (status, body)

        status, _, body = exchange(port, b"GET /hello/" + b"x" * 57 + b" HTTP/1.1\r\nHost: x\r\n\r\n")
        assert status == 422 and json.loads(body)["error"]["code"] == "name_too_long", body

        note = b'{"text":"milk","pinned":true}'
        status, fields, body = exchange(port, b"POST /notes HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\n"
                                              b"Content-Length: " + str(len(note)).encode() + b"\r\n\r\n" + note)
        assert status == 201 and body == note, (status, body)

        bad = b'{"text":"milk","extra":1}'
        status, _, body = exchange(port, b"POST /notes HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\n"
                                         b"Content-Length: " + str(len(bad)).encode() + b"\r\n\r\n" + bad)
        assert status == 422 and json.loads(body)["error"]["code"] == "invalid_payload", body

        status, _, body = exchange(port, b"GET /notes HTTP/1.1\r\nHost: x\r\n\r\n")
        assert status == 405, status
        assert process.poll() is None
    finally:
        process.terminate()
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
    print("Hello example tests passed: health, path parameters, typed POST 201, codec 422, logger request IDs")


if __name__ == "__main__":
    executable = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[2] / "build/hello"
    test_hello(executable)
