#!/usr/bin/env python3
"""End-to-end check for examples/pages: layouts, flash messages, CSRF, validation re-rendering, 404.

Every case runs on one keep-alive connection, so responses are framed by Content-Length. A small
cookie jar carries the session and CSRF cookies the way a browser would.
"""
from pathlib import Path
import re
import socket
import subprocess
import sys
import time
from urllib.parse import quote


def read_response(client, head=False):
    """Returns (status, headers, body); headers is a list of (name, value) byte pairs."""
    buffer = b""
    while b"\r\n\r\n" not in buffer:
        chunk = client.recv(16384)
        assert chunk, "connection closed before response headers"
        buffer += chunk
    head_text, body = buffer.split(b"\r\n\r\n", 1)
    lines = head_text.split(b"\r\n")
    status = int(lines[0].split(b" ", 2)[1])
    headers = [tuple(line.split(b": ", 1)) for line in lines[1:]]
    length = 0
    for name, value in headers:
        if name.lower() == b"content-length":
            length = int(value)
    if head:
        length = 0
    while len(body) < length:
        chunk = client.recv(16384)
        assert chunk, "connection closed inside response body"
        body += chunk
    return status, headers, body[:length]


class Client:
    """One keep-alive connection plus a cookie jar updated from Set-Cookie headers."""

    def __init__(self, port):
        self.socket = socket.create_connection(("127.0.0.1", port), timeout=3)
        self.cookies = {}

    def close(self):
        self.socket.close()

    def request(self, method, path, form=None, raw=None, content_type=None, headers=()):
        body = b""
        if form is not None:
            body = "&".join(f"{key}={quote(value, safe='')}" for key, value in form).encode()
            content_type = "application/x-www-form-urlencoded"
        if raw is not None:
            body = raw
        head = f"{method} {path} HTTP/1.1\r\nHost: x\r\n"
        if self.cookies:
            head += "Cookie: " + "; ".join(f"{k}={v}" for k, v in self.cookies.items()) + "\r\n"
        if content_type is not None:
            head += f"Content-Type: {content_type}\r\n"
        for line in headers:
            head += line + "\r\n"
        if body or method == "POST":
            head += f"Content-Length: {len(body)}\r\n"
        self.socket.sendall(head.encode() + b"\r\n" + body)
        status, response_headers, payload = read_response(self.socket)
        for name, value in response_headers:
            if name.lower() == b"set-cookie":
                pair, *attributes = value.decode().split("; ")
                key, _, cookie_value = pair.partition("=")
                if "Max-Age=0" in attributes:
                    self.cookies.pop(key, None)
                else:
                    self.cookies[key] = cookie_value
        return status, dict((name.lower(), value) for name, value in response_headers), payload.decode()


def csrf_token(html):
    match = re.search(r'name="csrf_token" value="([^"]+)"', html)
    assert match, html
    return match.group(1)


def test_pages(executable):
    with socket.socket() as reservation:
        reservation.bind(("127.0.0.1", 0))
        port = reservation.getsockname()[1]
    process = subprocess.Popen([str(executable), "--port", str(port)], stdout=subprocess.DEVNULL)
    client = None
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

        client = Client(port)

        # The list renders in the layout: nav with the active link, the empty state, the form.
        status, headers, html = client.request("GET", "/")
        assert status == 200 and headers[b"content-type"] == b"text/html; charset=utf-8", (status, headers)
        assert "<title>Todos · Todo Pages</title>" in html, html
        assert 'class="active" aria-current="page">Todos</a>' in html, html
        assert "Nothing here for this filter." in html and "0 open, 0 done" in html, html
        assert headers[b"x-frame-options"] == b"DENY" and b"default-src" in headers[b"content-security-policy"]
        token = csrf_token(html)
        assert client.cookies.get("gw_csrf") == token, client.cookies

        # A write without the token is refused before the handler runs.
        status, _, body = client.request("POST", "/todos", form=[("title", "No token")])
        assert status == 403 and '"code":"csrf_failed"' in body, (status, body)

        # Adding a todo redirects; the flash arrives with the redirect and shows on the next page.
        title = "<b>Buy milk</b> & eggs"
        status, headers, _ = client.request("POST", "/todos", form=[("csrf_token", token), ("title", title)])
        assert status == 303 and headers[b"location"] == b"/", (status, headers)
        status, _, html = client.request("GET", "/")
        assert status == 200
        assert 'class="flash flash-ok" role="status">Todo added</p>' in html, html
        assert "&lt;b&gt;Buy milk&lt;/b&gt; &amp; eggs" in html and "<b>Buy" not in html, html
        assert "1 open, 0 done" in html and "Nothing here" not in html, html
        # Shown once: the next page has no flash.
        status, _, html = client.request("GET", "/")
        assert "flash-ok" not in html, html

        # Empty title: an error flash, the list unchanged.
        status, _, _ = client.request("POST", "/todos", form=[("csrf_token", token), ("title", "")])
        assert status == 303, status
        status, _, html = client.request("GET", "/")
        assert 'class="flash flash-error" role="status">Title is required</p>' in html, html

        # Detail: the layout's head block (noindex) only on this page, and the title escaped.
        status, _, html = client.request("GET", "/todos/1")
        assert status == 200 and '<meta name="robots" content="noindex">' in html, html
        assert "<h1>&lt;b&gt;Buy milk&lt;/b&gt; &amp; eggs</h1>" in html and "Status: open" in html, html
        status, _, html = client.request("GET", "/")
        assert "robots" not in html

        # A missing todo gets the 404 page, rendered with the layout.
        status, _, html = client.request("GET", "/todos/99")
        assert status == 404 and "<h1>Page not found</h1>" in html and "Todo Pages" in html, (status, html)
        status, _, html = client.request("GET", "/no/such/page")
        assert status == 404 and "<h1>Page not found</h1>" in html, (status, html)

        # Edit form: the current title, prefilled and escaped.
        status, _, html = client.request("GET", "/todos/1/edit")
        assert status == 200 and 'value="&lt;b&gt;Buy milk&lt;/b&gt; &amp; eggs"' in html, html

        # Validation: blank-looking input comes back as 422 with the typed value and the error.
        status, _, html = client.request("POST", "/todos/1/edit", form=[("csrf_token", token), ("title", "   ")])
        assert status == 422, status
        assert 'value="   "' in html and 'role="alert">Title is required' in html, html
        assert "Edit todo 1" in html, html

        # Valid edit: redirect to the detail page, flash saved, new title shown.
        status, headers, _ = client.request("POST", "/todos/1/edit", form=[("csrf_token", token), ("title", "Buy oat milk")])
        assert status == 303 and headers[b"location"] == b"/todos/1", (status, headers)
        status, _, html = client.request("GET", "/todos/1")
        assert 'flash-ok" role="status">Todo saved' in html and "<h1>Buy oat milk</h1>" in html, html

        # A second todo, then toggle the first to done and check the filter tabs.
        status, _, _ = client.request("POST", "/todos", form=[("csrf_token", token), ("title", "Walk")])
        assert status == 303
        status, headers, _ = client.request("POST", "/todos/1/toggle", form=[("csrf_token", token)])
        assert status == 303 and headers[b"location"] == b"/", (status, headers)
        status, _, html = client.request("GET", "/?filter=open")
        assert "Buy oat milk" not in html and "Walk" in html, html
        assert '<a href="/?filter=open" class="active">Open</a>' in html, html
        status, _, html = client.request("GET", "/?filter=done")
        assert "Buy oat milk" in html and "Walk" not in html, html
        assert "1 open, 1 done" in html or "1 open, 1 done" in client.request("GET", "/")[2], html
        status, _, html = client.request("GET", "/?filter=bogus")
        assert "Buy oat milk" in html and "Walk" in html, html

        # Delete with the CSRF token: redirect, flash, then the detail page is gone.
        status, headers, _ = client.request("POST", "/todos/1/delete", form=[("csrf_token", token)])
        assert status == 303 and headers[b"location"] == b"/", (status, headers)
        status, _, html = client.request("GET", "/")
        assert "Todo deleted" in html and "Buy oat milk" not in html, html
        status, _, _ = client.request("GET", "/todos/1")
        assert status == 404

        # Static files come from examples/pages/public with their own content type.
        status, headers, css = client.request("GET", "/static/style.css")
        assert status == 200 and headers[b"content-type"] == b"text/css; charset=utf-8", (status, headers)
        assert ":root" in css, css

        # Same connection, still framed correctly after every case above.
        status, _, _ = client.request("GET", "/")
        assert status == 200
        assert process.poll() is None
    finally:
        if client is not None:
            client.close()
        process.terminate()
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
    print("Pages example tests passed: layout and nav, flash shown once, CSRF 403, validation 422 re-render, "
          "detail head block, 404 page, edit, toggle, filters, delete, static CSS, one keep-alive connection")


if __name__ == "__main__":
    executable = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[2] / "build/pages"
    test_pages(executable)
