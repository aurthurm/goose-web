#!/usr/bin/env python3
"""Live checks for the app DSL (c.routes, groups, params, 404/405) over real sockets."""
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


def exchange(port, raw):
    with socket.create_connection(("127.0.0.1", port), timeout=3) as client:
        client.sendall(raw)
        headers, body = read_response(client, raw.startswith(b"HEAD "))
    status = int(headers.split(b" ", 2)[1])
    fields = dict(line.split(b": ", 1) for line in headers.split(b"\r\n")[1:])
    return status, fields, body


def exchange_lines(port, raw):
    """Like exchange, but keeps every header line in order (for repeated Set-Cookie)."""
    with socket.create_connection(("127.0.0.1", port), timeout=3) as client:
        client.sendall(raw)
        headers, body = read_response(client, raw.startswith(b"HEAD "))
    status = int(headers.split(b" ", 2)[1])
    lines = [tuple(line.split(b": ", 1)) for line in headers.split(b"\r\n")[1:]]
    return status, lines, body


def get(path, extra=b""):
    return b"GET " + path + b" HTTP/1.1\r\nHost: x\r\n" + extra + b"\r\n"


def test_app(executable):
    root = Path(__file__).resolve().parents[2]
    with socket.socket() as reservation:
        reservation.bind(("127.0.0.1", 0))
        port = reservation.getsockname()[1]
    # The static directory is relative to the repository root.
    process = subprocess.Popen([str(executable), str(port)], stdout=subprocess.DEVNULL, cwd=root)
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
        status, fields, body = exchange(port, b"GET /users/42 HTTP/1.1\r\nHost: x\r\n\r\n")
        first_id = int(fields[b"X-Request-ID"])
        assert first_id > 0 and fields[b"Access-Control-Allow-Origin"] == b"*", fields

        def send_json(raw_body, content_type=b"application/json"):
            request = (b"POST /api/items HTTP/1.1\r\nHost: x\r\nContent-Type: " + content_type +
                       b"\r\nContent-Length: " + str(len(raw_body)).encode() + b"\r\n\r\n" + raw_body)
            return exchange(port, request)

        status, fields, body = send_json(b'{"title":"milk"}')
        assert status == 201 and body == b'{"id":1,"title":"milk","done":false}', (status, body)
        assert fields[b"Content-Type"] == b"application/json"
        assert int(fields[b"X-Request-ID"]) > first_id

        status, fields, body = exchange(port, b"GET /api/items HTTP/1.1\r\nHost: x\r\n\r\n")
        assert status == 200 and body == b'[{"id":1,"title":"milk","done":false}]', body

        status, _, body = send_json(b"{}", b"text/plain")
        assert status == 415 and json.loads(body)["error"]["code"] == "unsupported_media_type", body

        status, _, body = send_json(b'{"title":')
        assert status == 400 and json.loads(body)["error"]["code"] == "invalid_json", body

        status, _, body = send_json(b'{"title":"a","zzz":1}')
        assert status == 422 and json.loads(body)["error"]["code"] == "invalid_payload", body
        assert b"zzz: unknown key" in body, body

        status, fields, _ = exchange(port, b"OPTIONS /api/items HTTP/1.1\r\nHost: x\r\nOrigin: https://a.example\r\n"
                                     b"Access-Control-Request-Method: POST\r\n"
                                     b"Access-Control-Request-Headers: Content-Type\r\n\r\n")
        assert status == 204 and fields[b"Access-Control-Allow-Origin"] == b"*", fields
        assert fields[b"Access-Control-Allow-Methods"] == b"GET, POST, PUT, PATCH, DELETE, OPTIONS", fields
        assert fields[b"Access-Control-Allow-Headers"] == b"Content-Type" and fields[b"Access-Control-Max-Age"] == b"600"
        assert b"X-Request-ID" in fields, fields

        # Typed query binding: every class, percent and plus decoding, defaults for missing keys.
        status, _, body = exchange(port, get(b"/search?limit=-5&q=a%20b+c&active=1&score=2.5"))
        assert status == 200, body
        found = json.loads(body)
        assert found == {"limit": -5, "q": "a b c", "active": True, "score": 2.5}, found
        status, _, body = exchange(port, get(b"/search"))
        assert status == 200 and json.loads(body) == {"limit": 10, "q": "", "active": False, "score": 0.0}, body
        status, _, body = exchange(port, get(b"/search?limit=x"))
        assert status == 400 and json.loads(body)["error"]["code"] == "invalid_query", body
        assert b"limit: expected an integer" in body, body
        status, _, body = exchange(port, get(b"/search?nope=1"))
        assert status == 400 and b"nope: unknown key" in body, body
        status, _, body = exchange(port, get(b"/search?limit=1&limit=2"))
        assert status == 400 and b"limit: duplicate query parameter" in body, body
        status, _, body = exchange(port, get(b"/search?q=0123456789abcdefgh0123456789abcdefgh"))
        assert status == 400 and b"q: string too long" in body, body

        # Cookies: two repeated Set-Cookie lines, and a Cookie header read back.
        status, lines, body = exchange_lines(port, get(b"/cookies/set"))
        assert status == 200 and body == b"cookies set", body
        set_cookies = [value for name, value in lines if name == b"Set-Cookie"]
        assert set_cookies == [
            b"session=abc123; Path=/; Max-Age=3600; HttpOnly; Secure; SameSite=Strict",
            b"theme=dark; Path=/app; SameSite=Lax",
        ], set_cookies
        status, _, body = exchange(port, get(b"/cookies/echo", b"Cookie: theme=light; session=xyz\r\n"))
        assert status == 200 and body == b"session=xyz;theme=light", body

        # Static files: content types, index and directory mapping, HEAD, and every refusal class.
        status, fields, body = exchange(port, get(b"/static/hello.txt"))
        assert status == 200 and body == b"hello from a static file\n", body
        assert fields[b"Content-Type"] == b"text/plain; charset=utf-8", fields
        assert fields[b"X-Content-Type-Options"] == b"nosniff", fields
        status, fields, body = exchange(port, get(b"/static/"))
        assert status == 200 and b"Static index" in body and fields[b"Content-Type"] == b"text/html; charset=utf-8"
        status, fields, body = exchange(port, get(b"/static/style.css"))
        assert status == 200 and fields[b"Content-Type"] == b"text/css; charset=utf-8", fields
        status, _, body = exchange(port, get(b"/static/docs"))
        assert status == 200 and b"docs index" in body, body
        status, fields, body = exchange(port, b"HEAD /static/hello.txt HTTP/1.1\r\nHost: x\r\n\r\n")
        assert status == 200 and body == b"" and int(fields[b"Content-Length"]) == 25, fields
        status, _, body = exchange(port, get(b"/static/missing.txt"))
        assert status == 404 and json.loads(body)["error"]["code"] == "not_found", body
        status, _, body = exchange(port, get(b"/static/.hidden"))
        assert status == 404, body
        for bad in (b"/static/../health", b"/static/%2e%2e/health", b"/static/a%2Fb", b"/static/a%5Cb",
                    b"/static/a%00b", b"/static//etc/passwd", b"/static/a/./b"):
            status, _, body = exchange(port, get(bad))
            assert status == 400 and json.loads(body)["error"]["code"] == "invalid_path", (bad, status, body)
        status, _, body = exchange(port, b"POST /static/hello.txt HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\n\r\n")
        assert status == 404, body
        status, _, body = exchange(port, get(b"/health"))
        assert status == 200, body
        assert process.poll() is None
    finally:
        process.terminate()
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
    print("App socket tests passed: routes, groups, path params, 404, 405, HEAD, JSON 201/415/400/422, CORS preflight, "
          "X-Request-ID, typed query, cookies, repeated Set-Cookie, static files and refusals")


if __name__ == "__main__":
    executable = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[2] / "build/app"
    test_app(executable)
