#!/usr/bin/env python3
"""Live checks for wildcards, host scopes, typed path parameters, the peer address, rate limiting
and secure headers over real sockets (tests/fixtures/routing.goose)."""
from pathlib import Path
import json
import socket
import subprocess
import sys
import time


def read_response(client, head=False):
    # HTTP/1.1 connections persist by default, so frame by Content-Length instead of EOF.
    buffer = b""
    while b"\r\n\r\n" not in buffer:
        chunk = client.recv(16384)
        assert chunk, "connection closed before response headers"
        buffer += chunk
    headers, body = buffer.split(b"\r\n\r\n", 1)
    fields = dict(line.split(b": ", 1) for line in headers.split(b"\r\n")[1:])
    length = 0 if head else int(fields.get(b"Content-Length", b"0"))
    while len(body) < length:
        chunk = client.recv(16384)
        assert chunk, "connection closed inside response body"
        body += chunk
    return headers, body[:length]


def exchange(port, raw, source=None):
    with socket.create_connection(("127.0.0.1", port), timeout=3, source_address=source) as client:
        client.sendall(raw)
        headers, body = read_response(client, raw.startswith(b"HEAD "))
    status = int(headers.split(b" ", 2)[1])
    fields = dict(line.split(b": ", 1) for line in headers.split(b"\r\n")[1:])
    return status, fields, body


def get(path, host=b"x", extra=b""):
    return b"GET " + path + b" HTTP/1.1\r\nHost: " + host + b"\r\n" + extra + b"\r\n"


def test_routing(executable):
    root = Path(__file__).resolve().parents[2]
    with socket.socket() as reservation:
        reservation.bind(("127.0.0.1", 0))
        port = reservation.getsockname()[1]
    process = subprocess.Popen([str(executable), str(port)], stdout=subprocess.DEVNULL, cwd=root)
    try:
        deadline = time.monotonic() + 3
        while True:
            if process.poll() is not None:
                raise AssertionError("routing server exited during startup")
            try:
                with socket.create_connection(("127.0.0.1", port), timeout=0.1):
                    break
            except ConnectionRefusedError:
                if time.monotonic() > deadline:
                    raise
                time.sleep(0.02)

        # The peer address comes from accept(); two loopback sources are two clients.
        status, _, body = exchange(port, get(b"/peer"))
        assert status == 200 and body == b"127.0.0.1", (status, body)
        status, _, body = exchange(port, get(b"/peer"), source=("127.0.0.2", 0))
        assert status == 200 and body == b"127.0.0.2", (status, body)

        # Secure headers wrap every response: fixed set, default CSP, no HSTS unless configured.
        status, fields, _ = exchange(port, get(b"/peer"))
        assert fields[b"X-Content-Type-Options"] == b"nosniff", fields
        assert fields[b"X-Frame-Options"] == b"DENY", fields
        assert fields[b"Referrer-Policy"] == b"strict-origin-when-cross-origin", fields
        assert fields[b"Content-Security-Policy"] == b"default-src 'self'", fields
        assert b"Strict-Transport-Security" not in fields, fields
        status, fields, _ = exchange(port, get(b"/missing"))
        assert status == 404 and fields[b"X-Frame-Options"] == b"DENY", fields

        # Rate limit: three requests per client per minute; the fourth is 429 with Retry-After.
        for _ in range(3):
            status, _, body = exchange(port, get(b"/limited"))
            assert status == 200 and body == b"limited ok", (status, body)
        status, fields, body = exchange(port, get(b"/limited"))
        assert status == 429 and json.loads(body)["error"]["code"] == "rate_limited", body
        assert 1 <= int(fields[b"Retry-After"]) <= 60, fields
        assert fields[b"X-Frame-Options"] == b"DENY", fields
        status, _, body = exchange(port, get(b"/limited"), source=("127.0.0.2", 0))
        assert status == 200 and body == b"limited ok", (status, body)

        # Wildcards: the raw rest of the path, slashes included; empty rest is 404.
        status, _, body = exchange(port, get(b"/files/a/b.txt"))
        assert status == 200 and body == b"a/b.txt", body
        status, _, body = exchange(port, get(b"/files/a%20b/c"))
        assert status == 200 and body == b"a%20b/c", body
        status, _, body = exchange(port, get(b"/files/"))
        assert status == 404 and json.loads(body)["error"]["code"] == "not_found", body
        status, fields, body = exchange(port, b"HEAD /files/a/b.txt HTTP/1.1\r\nHost: x\r\n\r\n")
        assert status == 200 and body == b"" and int(fields[b"Content-Length"]) == len(b"a/b.txt"), fields
        status, _, body = exchange(port, b"POST /files/a HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\n\r\n")
        assert status == 405 and body, body

        # Host scopes: Host without its port, case-insensitive; other hosts get the unscoped route.
        status, _, body = exchange(port, get(b"/whoami", host=b"API.localhost:8080"))
        assert status == 200 and body == b"api", body
        status, _, body = exchange(port, get(b"/whoami", host=b"www.localhost"))
        assert status == 200 and body == b"wild", body
        status, _, body = exchange(port, get(b"/whoami", host=b"a.b.localhost"))
        assert status == 200 and body == b"plain", body
        status, _, body = exchange(port, get(b"/whoami", host=b"other.test"))
        assert status == 200 and body == b"plain", body
        status, fields, _ = exchange(port, b"DELETE /whoami HTTP/1.1\r\nHost: api.localhost\r\n\r\n")
        assert status == 405 and fields[b"Allow"] == b"GET, HEAD", fields

        # Typed path parameters: canonical forms bind; anything else is 422 invalid_param.
        status, _, body = exchange(port, get(b"/u/123E4567-E89B-12D3-A456-426614174000"))
        assert status == 200 and body == b"123E4567-E89B-12D3-A456-426614174000", body
        status, _, body = exchange(port, get(b"/u/123E4567-e89b-12d3-a456-426614174000"))
        assert status == 422 and json.loads(body)["error"]["code"] == "invalid_param", body
        status, _, body = exchange(port, get(b"/n/18446744073709551615"))
        assert status == 200 and body == b"18446744073709551615", body
        status, _, body = exchange(port, get(b"/n/18446744073709551616"))
        assert status == 422 and json.loads(body)["error"]["code"] == "invalid_param", body
        status, _, body = exchange(port, get(b"/s/hello-2"))
        assert status == 200 and body == b"hello-2", body
        status, _, body = exchange(port, get(b"/s/Hello"))
        assert status == 422 and json.loads(body)["error"]["code"] == "invalid_param", body

        # Several requests on one keep-alive connection, with the host changing between them.
        with socket.create_connection(("127.0.0.1", port), timeout=3) as client:
            for host, expected in ((b"api.localhost", b"api"), (b"x.localhost", b"wild"), (b"nope.test", b"plain")):
                client.sendall(get(b"/whoami", host=host))
                headers, body = read_response(client)
                assert headers.startswith(b"HTTP/1.1 200") and body == expected, (host, body)
        assert process.poll() is None
    finally:
        process.terminate()
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
    print("Routing socket tests passed: peer address, secure headers, rate limit, wildcards, host scopes, "
          "typed path parameters, keep-alive host changes")


if __name__ == "__main__":
    executable = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[2] / "build/routing"
    test_routing(executable)
