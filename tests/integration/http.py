#!/usr/bin/env python3
"""Live HTTP checks against the basic example; no compiler/build responsibilities."""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import json
import socket
import subprocess
import sys
import time

def exchange(port, raw, fragments=False):
    with socket.create_connection(("127.0.0.1", port), timeout=3) as client:
        if fragments:
            for start in range(0, len(raw), 7):
                client.sendall(raw[start:start + 7])
                time.sleep(0.001)
        else:
            client.sendall(raw)
        chunks = []
        while chunk := client.recv(16384):
            chunks.append(chunk)
    wire = b"".join(chunks)
    headers, body = wire.split(b"\r\n\r\n", 1)
    status = int(headers.split(b" ", 2)[1])
    fields = dict(line.split(b": ", 1) for line in headers.split(b"\r\n")[1:])
    assert fields[b"Connection"] == b"close"
    if not raw.startswith(b"HEAD "):
        assert int(fields[b"Content-Length"]) == len(body), wire
    return status, fields, body


def health(port):
    status, fields, body = exchange(port, b"GET /health HTTP/1.1\r\nHost: localhost\r\n\r\n")
    assert status == 200 and body == b'{"status":"ok"}\n'
    assert fields[b"Content-Type"] == b"application/json"
    assert int(fields[b"X-Request-ID"]) > 0


def malformed_requests(port):
    # These complete requests must be rejected before any application handler.
    # They exercise the actual connection/parser boundary, not just pure parsing.
    cases = [
        b"GET /health HTTP/1.1\r\nHost: local host\r\n\r\n",
        b"GET /health HTTP/1.1\r\nHost: localhost:abc\r\n\r\n",
        b"GET /health HTTP/1.1\r\nHost: user@localhost\r\n\r\n",
        b"GET /health HTTP/1.1\r\nHost: [not-an-ip]\r\n\r\n",
        b"GET /health#fragment HTTP/1.1\r\nHost: x\r\n\r\n",
        b"GET /bad%GG HTTP/1.1\r\nHost: x\r\n\r\n",
        b"GET /bad\xff HTTP/1.1\r\nHost: x\r\n\r\n",
        b"GET /health HTTP/1.1\r\nHost: x\r\nX: value\nHidden: yes\r\n\r\n",
        b"GET /health HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\nContent-Length: 0\r\n\r\n",
        b"GET /health HTTP/1.1\r\nHost: x\r\nContent-Length: 0, 0\r\n\r\n",
        b"GET /health HTTP/1.1\r\nHost: x\r\nContent-Length: +0\r\n\r\n",
    ]
    for raw in cases:
        status, headers, _ = exchange(port, raw)
        assert status == 400, (raw, status)
        assert b"X-Request-ID" not in headers, "malformed request reached middleware"
    # Binary and HTTP-looking body bytes belong to the declared first body only.
    body = b"\x00\xffGET /missing HTTP/1.1\r\nHost: body\r\n\r\n"
    first = (b"POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: " +
             str(len(body)).encode() + b"\r\n\r\n" + body)
    extra = b"GET /health HTTP/1.1\r\nHost: x\r\n\r\n"
    status, _, echoed = exchange(port, first + extra)
    assert status == 200 and echoed == body


def test_server(executable):
    with socket.socket() as reservation:
        reservation.bind(("127.0.0.1", 0))
        port = reservation.getsockname()[1]
    process = subprocess.Popen([str(executable), str(port)], stdout=subprocess.DEVNULL)
    try:
        deadline = time.monotonic() + 3
        while True:
            if process.poll() is not None:
                raise AssertionError("server exited during startup")
            try:
                with socket.create_connection(("127.0.0.1", port), timeout=0.1):
                    break
            except ConnectionRefusedError:
                if time.monotonic() > deadline:
                    raise
                time.sleep(0.02)
        health(port)
        malformed_requests(port)
        with socket.create_connection(("127.0.0.1", port), timeout=3) as slow:
            slow.sendall(b"GET /health HTTP/1.1\r\nHost:")
            start = time.monotonic()
            health(port)
            assert time.monotonic() - start < 1, "incomplete client blocked another request"
            slow.sendall(b" localhost\r\n\r\n")
            result = b""
            while chunk := slow.recv(4096):
                result += chunk
            assert b"200 OK" in result
        with ThreadPoolExecutor(max_workers=24) as pool:
            list(pool.map(health, [port] * 48))
        payload = b"hello\x00from goose\xff"
        status, _, body = exchange(port, b"POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: " +
                                   str(len(payload)).encode() + b"\r\n\r\n" + payload, fragments=True)
        assert status == 200 and body == payload
        # Exact request-buffer boundary, including headers and body.
        length = 8133
        prefix = b"POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: " + str(length).encode() + b"\r\n\r\n"
        length = 8192 - len(prefix)
        prefix = b"POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: " + str(length).encode() + b"\r\n\r\n"
        raw = prefix + b"x" * length
        assert len(raw) == 8192
        status, _, body = exchange(port, raw)
        assert status == 200 and body == b"x" * length
        status, fields, body = exchange(port, b"HEAD /health HTTP/1.1\r\nHost: x\r\n\r\n")
        assert status == 200 and body == b"" and int(fields[b"Content-Length"]) > 0
        assert exchange(port, b"GET /missing HTTP/1.1\r\nHost: x\r\n\r\n")[0] == 404
        status, fields, body = exchange(port, b"POST /health HTTP/1.1\r\nHost: x\r\n\r\n")
        assert status == 405 and fields[b"Allow"] == b"GET, HEAD"
        assert json.loads(body)["error"]["code"] == "method_not_allowed"
        status, _, body = exchange(port, b"GET /missing HTTP/1.1\r\nHost: x\r\n\r\n")
        assert status == 404 and json.loads(body)["error"]["code"] == "not_found"
        status, _, body = exchange(port, b"GET /users/42?ignored=1 HTTP/1.1\r\nHost: x\r\n\r\n")
        assert status == 200 and body == b"42"
        status, _, body = exchange(port, b"GET /users/new HTTP/1.1\r\nHost: x\r\n\r\n")
        assert status == 200 and body == b"New user form\n"
        status, fields, _ = exchange(port, b"POST /users/new HTTP/1.1\r\nHost: x\r\n\r\n")
        assert status == 405 and fields[b"Allow"] == b"GET, HEAD"
        status, _, body = exchange(port, b"GET /greet?name=Goose+Web%21 HTTP/1.1\r\nHost: x\r\n\r\n")
        assert status == 200 and body == b"Hello, Goose Web!!\n"
        # A syntactically valid URI can still exceed the decoded query limit.
        raw = b"GET /greet?name=" + b"x" * 1025 + b" HTTP/1.1\r\nHost: x\r\n\r\n"
        status, _, body = exchange(port, raw)
        assert status == 413 and json.loads(body)["error"]["code"] == "invalid_query"
        status, fields, body = exchange(port, b"POST /echo HTTP/1.1\r\nHost: x\r\nx-demo-reject: yes\r\nContent-Length: 5\r\n\r\nhello")
        assert status == 403 and json.loads(body)["error"]["code"] == "request_rejected"
        assert b"X-Request-ID" in fields
        cases = [
            (b"GET / HTTP/1.1\r\n\r\n", 400),
            (b"GET / HTTP/1.1\r\nHost: x\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\nxx", 400),
            (b"GET / HTTP/1.1\r\nHost: x\r\nContent-Length: 999999999999999999999999\r\n\r\n", 413),
            (b"GET / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n", 501),
            (b"POST / HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\n\r\n", 417),
            (b"x" * 8192, 431),
        ]
        for raw, expected in cases:
            assert exchange(port, raw)[0] == expected
        for raw in (b"GET /", b"GET /health HTTP/1.1\r\nHost: x\r\n\r\n"):
            with socket.create_connection(("127.0.0.1", port), timeout=3) as client:
                client.sendall(raw)
        health(port)
        with socket.create_connection(("127.0.0.1", port), timeout=7) as idle:
            idle.sendall(b"GET /")
            assert idle.recv(1) == b"", "incomplete request did not expire"
        health(port)
        assert process.poll() is None
    finally:
        process.terminate()
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
    print("Socket tests passed: concurrency, fragmentation, limits, routing, query decoding, middleware, errors, headers, timeout")


if __name__ == "__main__":
    executable = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[2] / "build/server"
    test_server(executable)
