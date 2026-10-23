#!/usr/bin/env python3
"""End-to-end Todo API contract checks. Pass an already-built basic server."""
from contextlib import contextmanager
from pathlib import Path
import json
import socket
import subprocess
import sys
import tempfile
import time


def free_port():
    with socket.socket() as reservation:
        reservation.bind(("127.0.0.1", 0))
        return reservation.getsockname()[1]


def request(port, method, target, value=None, *, raw=None, content_type="application/json"):
    body = raw if raw is not None else (json.dumps(value, ensure_ascii=False).encode() if value is not None else b"")
    # One exchange per socket: ask for close so the response ends at EOF, as this helper expects.
    headers = f"{method} {target} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\nContent-Length: {len(body)}\r\n"
    if content_type is not None:
        headers += f"Content-Type: {content_type}\r\n"
    with socket.create_connection(("127.0.0.1", port), timeout=3) as client:
        client.sendall(headers.encode() + b"\r\n" + body)
        chunks = []
        while chunk := client.recv(16384):
            chunks.append(chunk)
    header_bytes, payload = b"".join(chunks).split(b"\r\n\r\n", 1)
    lines = header_bytes.split(b"\r\n")
    status = int(lines[0].split(b" ")[1])
    fields = {key.decode().lower(): val.decode() for key, val in (line.split(b": ", 1) for line in lines[1:])}
    assert fields["connection"] == "close"
    if method == "HEAD" or status == 204:
        assert payload == b"", (status, payload)
    else:
        assert int(fields["content-length"]) == len(payload)
    return status, fields, payload


def application(port, method, target, expected, value=None, **kwargs):
    status, headers, payload = request(port, method, target, value, **kwargs)
    assert status == expected, (method, target, expected, status, payload)
    assert int(headers["x-request-id"]) > 0, headers
    parsed = None
    if payload:
        assert headers["content-type"].split(";", 1)[0] == "application/json"
        parsed = json.loads(payload)
        if status >= 400:
            assert set(parsed) == {"error"}
            assert set(parsed["error"]) == {"code", "message"}
            assert isinstance(parsed["error"]["code"], str)
            assert isinstance(parsed["error"]["message"], str)
    return parsed, headers


@contextmanager
def server(executable, datafile):
    port = free_port()
    process = subprocess.Popen([str(executable), str(port), "0", str(datafile)],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        deadline = time.monotonic() + 5
        while True:
            assert process.poll() is None, "Todo server exited during startup"
            try:
                with socket.create_connection(("127.0.0.1", port), timeout=0.1):
                    break
            except ConnectionRefusedError:
                if time.monotonic() >= deadline:
                    raise AssertionError("Todo server did not start")
                time.sleep(0.02)
        yield port
        assert process.poll() is None, "Todo server exited unexpectedly"
    finally:
        if process.poll() is None:
            process.terminate()
        try:
            process.wait(timeout=6)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=3)


def assert_todo(todo, title, completed=False):
    assert set(todo) == {"id", "title", "completed"}, todo
    assert type(todo["id"]) is int and todo["id"] > 0
    assert todo["title"] == title and todo["completed"] is completed


def test_crud(executable, directory):
    datafile = directory / "todos.json"
    with server(executable, datafile) as port:
        health, _ = application(port, "GET", "/health", 200)
        assert health == {"status": "ok"}
        application(port, "HEAD", "/health", 200)
        empty, _ = application(port, "GET", "/todos", 200)
        assert empty == {"items": [], "total": 0, "limit": 8, "offset": 0}
        title = r'  Read "Goose" \ docs / café 🪿  '
        first, headers = application(port, "POST", "/todos", 201, {"title": title})
        assert_todo(first, title)
        first_id = first["id"]
        assert headers["location"] == f"/todos/{first_id}"
        first_path = headers["location"]
        fetched, get_headers = application(port, "GET", first_path, 200)
        assert fetched == first
        _, head_headers = application(port, "HEAD", first_path, 200)
        assert head_headers["content-length"] == get_headers["content-length"]
        application(port, "HEAD", "/todos", 200)
        second, _ = application(port, "POST", "/todos", 201, {"title": "second", "completed": True})
        third, _ = application(port, "POST", "/todos", 201, {"title": "third"})
        assert first_id < second["id"] < third["id"]
        page, _ = application(port, "GET", "/todos?limit=1&offset=1", 200)
        assert page == {"items": [second], "total": 3, "limit": 1, "offset": 1}
        filtered, _ = application(port, "GET", "/todos?completed=false&limit=1&offset=1", 200)
        assert filtered == {"items": [third], "total": 2, "limit": 1, "offset": 1}
        filtered, _ = application(port, "GET", "/todos?completed=true", 200)
        assert filtered["items"] == [second] and filtered["total"] == 1
        beyond, _ = application(port, "GET", "/todos?offset=999", 200)
        assert beyond["items"] == [] and beyond["total"] == 3
        replaced, _ = application(port, "PUT", first_path, 200, {"title": "replaced", "completed": True})
        assert_todo(replaced, "replaced", True)
        assert replaced["id"] == first_id
        patched, _ = application(port, "PATCH", first_path, 200, {"completed": False})
        assert_todo(patched, "replaced")
        patched, _ = application(port, "PATCH", first_path, 200, {"title": title})
        assert_todo(patched, title)
        application(port, "DELETE", first_path, 204)
        application(port, "GET", first_path, 404)
        application(port, "DELETE", first_path, 404)
        fourth, _ = application(port, "POST", "/todos", 201, {"title": "fourth"})
        assert fourth["id"] > third["id"], "deleted IDs must never be reused"
        expected_items = [second, third, fourth]
    assert datafile.is_file(), "mutations did not persist"
    with server(executable, datafile) as port:
        restored, _ = application(port, "GET", "/todos", 200)
        assert restored["items"] == expected_items
        next_todo, _ = application(port, "POST", "/todos", 201, {"title": "after restart"})
        assert next_todo["id"] > fourth["id"]
    # Even deleting every record must preserve the next-ID counter on disk.
    with server(executable, datafile) as port:
        remaining, _ = application(port, "GET", "/todos", 200)
        for todo in remaining["items"]:
            application(port, "DELETE", f"/todos/{todo['id']}", 204)
    with server(executable, datafile) as port:
        after_empty, _ = application(port, "POST", "/todos", 201, {"title": "still monotonic"})
        assert after_empty["id"] > next_todo["id"]


def test_validation(executable):
    with server(executable, "--memory") as port:
        todo, _ = application(port, "POST", "/todos", 201, {"title": "original"})
        path = f"/todos/{todo['id']}"
        for method in ("POST", "PUT", "PATCH"):
            target = "/todos" if method == "POST" else path
            for content_type in (None, "text/plain", "application/jsonp"):
                application(port, method, target, 415, {"title": "x", "completed": True}, content_type=content_type)
            for raw in (b"", b"{", b'{"title":"x",}', b'{"title":"bad\x01"}', b'{"title":"\xff"}'):
                application(port, method, target, 400, raw=raw)
            for raw in (b"null", b"[]", b"true", b'{}', b'{"title":null}', b'{"title":4}',
                        b'{"title":"x","completed":1}', b'{"title":"x","unknown":true}',
                        b'{"title":"x","title":"y"}', rb'{"title":"x","tit\u006ce":"y"}',
                        rb'{"title":"x","completed":true,"complet\u0065d":false}'):
                application(port, method, target, 422, raw=raw)
            for title in ("", "   ", "\u3000", "\u00a0\u2003", "a\n", "a\t", "a\x00", "a\x7f", "x" * 129, "é" * 65):
                application(port, method, target, 422, {"title": title, "completed": False})
        application(port, "PUT", path, 422, {"title": "missing completed"})
        application(port, "PUT", path, 422, {"completed": True})
        unchanged, _ = application(port, "GET", path, 200)
        assert unchanged == todo, "rejected mutations changed live state"
        application(port, "POST", "/todos", 201, {"title": "charset accepted"},
                    content_type="application/json; charset=utf-8")
        boundary, _ = application(port, "POST", "/todos", 201, {"title": "é" * 64})
        assert len(boundary["title"].encode()) == 128
        for suffix in ("0", "01", "+1", "-1", "1x", "999999999999999999999999999999999999"):
            application(port, "GET", "/todos/" + suffix, 422)
        application(port, "GET", "/todos/999", 404)
        application(port, "GET", "/missing", 404)
        application(port, "HEAD", "/missing", 404)
        application(port, "HEAD", "/todos/0", 422)
        application(port, "HEAD", "/todos?completed=invalid", 422)
        for old in ("/echo", "/greet", "/users/1"):
            application(port, "GET", old, 404)
        for target, allowed in (("/todos", {"GET", "HEAD", "POST"}),
                                (path, {"GET", "HEAD", "PUT", "PATCH", "DELETE"})):
            _, headers = application(port, "OPTIONS", target, 405)
            assert set(headers["allow"].split(", ")) == allowed
        for query in ("limit=0", "limit=9", "limit=no", "offset=-1", "offset=no", "completed=1",
                      "completed=True", "unknown=x", "limit=1&limit=2", "completed=true&completed=false",
                      "li%6dit=1&limit=2", "limit=1&offset=0&extra=1"):
            application(port, "GET", "/todos?" + query, 422)
        application(port, "GET", "/todos?limit=" + "1" * 1025, 413)
        # Invalid URI escapes may be rejected before middleware assigns request IDs.
        status, _, _ = request(port, "GET", "/todos?limit=%GG")
        assert status == 400
        healthy, _ = application(port, "GET", "/health", 200)
        assert healthy == {"status": "ok"}


def test_storage_failure(executable, directory):
    original = directory / "storage"
    moved = directory / "storage-away"
    original.mkdir()
    with server(executable, original / "todos.json") as port:
        todo, _ = application(port, "POST", "/todos", 201, {"title": "durable"})
        original.rename(moved)
        try:
            for method, target, value in (("POST", "/todos", {"title": "lost"}),
                                          ("PUT", f"/todos/{todo['id']}", {"title": "lost", "completed": True}),
                                          ("PATCH", f"/todos/{todo['id']}", {"completed": True}),
                                          ("DELETE", f"/todos/{todo['id']}", None)):
                failure, _ = application(port, method, target, 500, value)
                assert failure["error"]["code"] == "storage_error"
                current, _ = application(port, "GET", "/todos", 200)
                assert current["items"] == [todo] and current["total"] == 1
        finally:
            moved.rename(original)
        created, _ = application(port, "POST", "/todos", 201, {"title": "recovered"})
        assert created["id"] == todo["id"] + 1, "failed create consumed an ID"


def test_corrupt_startup(executable, directory):
    datafile = directory / "corrupt.json"
    for corrupt in (b"not JSON", b"null", b"{}", b'{"next_id":1,"items":[null]}'):
        datafile.write_bytes(corrupt)
        process = subprocess.Popen([str(executable), str(free_port()), "0", str(datafile)],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            assert process.wait(timeout=5) != 0, "invalid storage must abort startup"
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=3)
        assert datafile.read_bytes() == corrupt, "startup overwrote corrupt storage"


def test_capacity(executable):
    with server(executable, "--memory") as port:
        for i in range(128):
            todo, _ = application(port, "POST", "/todos", 201, {"title": f"todo {i}"})
            assert todo["id"] == i + 1
        application(port, "POST", "/todos", 409, {"title": "overflow"})
        page, _ = application(port, "GET", "/todos", 200)
        assert len(page["items"]) == 8 and page["total"] == 128
        application(port, "DELETE", "/todos/64", 204)
        added, _ = application(port, "POST", "/todos", 201, {"title": "new slot"})
        assert added["id"] == 129


def read_framed(client, buffer):
    """One response from a keep-alive socket, framed by Content-Length. Returns the rest of the bytes."""
    while b"\r\n\r\n" not in buffer:
        chunk = client.recv(16384)
        assert chunk, "connection closed before the headers ended"
        buffer += chunk
    header_bytes, rest = buffer.split(b"\r\n\r\n", 1)
    lines = header_bytes.split(b"\r\n")
    status = int(lines[0].split(b" ")[1])
    fields = {key.decode().lower(): val.decode() for key, val in (line.split(b": ", 1) for line in lines[1:])}
    length = int(fields["content-length"])
    while len(rest) < length:
        chunk = client.recv(16384)
        assert chunk, "connection closed inside the body"
        rest += chunk
    return status, fields, rest[:length], rest[length:]


def test_openapi(executable):
    with server(executable, "--memory") as port:
        with socket.create_connection(("127.0.0.1", port), timeout=3) as client:
            # Two documents and a normal request on one keep-alive connection.
            client.sendall(b"GET /openapi.json HTTP/1.1\r\nHost: localhost\r\n\r\n")
            status, fields, payload, rest = read_framed(client, b"")
            assert status == 200 and fields["content-type"] == "application/json", fields
            assert len(payload) < 65536, "the document must fit the response cap"
            spec = json.loads(payload)
            assert spec["openapi"] == "3.1.0" and spec["info"]["title"] == "Goose Todo API"
            assert sorted(spec["paths"]) == ["/health", "/todos", "/todos/{id}"]
            assert sorted(spec["paths"]["/todos"]) == ["get", "post"]
            assert sorted(spec["paths"]["/todos/{id}"]) == ["delete", "get", "patch", "put"]
            assert spec["paths"]["/todos"]["post"]["requestBody"]["content"]["application/json"]["schema"]["required"] == ["title"]
            assert "/openapi.json" not in spec["paths"] and "/docs" not in spec["paths"]

            client.sendall(b"GET /docs HTTP/1.1\r\nHost: localhost\r\n\r\n")
            status, fields, page, rest = read_framed(client, rest)
            assert status == 200 and fields["content-type"].startswith("text/html"), fields
            assert b'url: "/openapi.json"' in page and b"cdn.jsdelivr.net/npm/swagger-ui-dist@" in page

            client.sendall(b"GET /todos HTTP/1.1\r\nHost: localhost\r\n\r\n")
            status, fields, payload, rest = read_framed(client, rest)
            assert status == 200 and json.loads(payload) == {"items": [], "total": 0, "limit": 8, "offset": 0}
            assert rest == b""


def main():
    executable = Path(sys.argv[1]).resolve()
    with tempfile.TemporaryDirectory(prefix="goose-todos-") as temporary:
        directory = Path(temporary)
        test_crud(executable, directory)
        test_validation(executable)
        test_storage_failure(executable, directory)
        test_corrupt_startup(executable, directory)
        test_capacity(executable)
        test_openapi(executable)
    print("Todo API tests passed: CRUD, pagination, validation, UTF-8, persistence, failure rollback, capacity, OpenAPI and docs")


if __name__ == "__main__":
    main()
