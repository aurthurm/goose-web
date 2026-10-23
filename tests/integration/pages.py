#!/usr/bin/env python3
"""End-to-end check for examples/pages: rendered list, form POST with redirect, escaping, errors.

Every case runs on one keep-alive connection, so responses are framed by Content-Length.
"""
from pathlib import Path
import socket
import subprocess
import sys
import time
from urllib.parse import quote


def read_response(client, head=False):
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


def send(client, method, path, body=b"", content_type=None):
    head = f"{method} {path} HTTP/1.1\r\nHost: x\r\n"
    if content_type is not None:
        head += f"Content-Type: {content_type}\r\n"
    if body or method == "POST":
        head += f"Content-Length: {len(body)}\r\n"
    client.sendall(head.encode() + b"\r\n" + body)
    headers, payload = read_response(client)
    status = int(headers.split(b" ", 2)[1])
    fields = dict(line.split(b": ", 1) for line in headers.split(b"\r\n")[1:])
    return status, fields, payload


def test_pages(executable):
    with socket.socket() as reservation:
        reservation.bind(("127.0.0.1", 0))
        port = reservation.getsockname()[1]
    process = subprocess.Popen([str(executable), "--port", str(port)], stdout=subprocess.DEVNULL)
    try:
        deadline = time.monotonic() + 3
        while True:
            assert process.poll() is None, "pages server exited during startup"
            try:
                with socket.create_connection(("127.0.0.1", port), timeout=0.1):
                    break
            except ConnectionRefusedError:
                if time.monotonic() > deadline:
                    raise
                time.sleep(0.02)

        form = "application/x-www-form-urlencoded"
        with socket.create_connection(("127.0.0.1", port), timeout=3) as client:
            status, fields, body = send(client, "GET", "/")
            assert status == 200 and fields[b"Content-Type"] == b"text/html; charset=utf-8", (status, fields)
            assert b"<h1>Todos</h1>" in body and b"No todos yet." in body, body
            assert b"<ul>" not in body

            # The payload must come back as escaped text, not markup.
            payload = quote("<script>alert(1)</script> & \"x\"").encode()
            status, fields, body = send(client, "POST", "/todos", b"title=" + payload, form)
            assert status == 303 and fields[b"Location"] == b"/" and body == b"", (status, fields)

            status, fields, body = send(client, "POST", "/todos", b"title=Buy+milk", form)
            assert status == 303, status

            # Same connection, next request: keep-alive framing still holds after redirects.
            status, fields, body = send(client, "GET", "/")
            assert status == 200, status
            assert b"<ul>" in body and b"2 todo(s)" in body, body
            assert b"&lt;script&gt;alert(1)&lt;/script&gt; &amp; &quot;x&quot;" in body, body
            assert b"<script>" not in body and b'"x"' not in body
            assert b"<li>Buy milk</li>" in body, body
            assert body.count(b"<li") == 2, body

            status, fields, body = send(client, "POST", "/todos", b"title=", form)
            assert status == 422 and b'"code":"title_required"' in body, (status, body)

            status, fields, body = send(client, "POST", "/todos", b"title=x", "application/json")
            assert status == 415 and b'"code":"unsupported_media_type"' in body, (status, body)

            status, fields, body = send(client, "POST", "/todos", b"title=x&color=red", form)
            assert status == 400 and b'"code":"invalid_form"' in body and b"color: unknown key" in body, (status, body)

            status, _, _ = send(client, "GET", "/")
            assert status == 200
        assert process.poll() is None
    finally:
        process.terminate()
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
    print("Pages example tests passed: embedded template render, form POST 303, escaping, 415/400/422 on one keep-alive connection")


if __name__ == "__main__":
    executable = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[2] / "build/pages"
    test_pages(executable)
