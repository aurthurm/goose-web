#!/usr/bin/env python3
"""examples/sqlite-todos over real sockets: CRUD, validation, keep-alive, restart persistence."""
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


def read_response(client):
    # Responses keep the connection open, so frame by Content-Length instead of EOF.
    buffer = b""
    while b"\r\n\r\n" not in buffer:
        chunk = client.recv(16384)
        assert chunk, "connection closed before response headers"
        buffer += chunk
    headers, body = buffer.split(b"\r\n\r\n", 1)
    fields = {k.lower(): v for k, v in (line.split(b": ", 1) for line in headers.split(b"\r\n")[1:])}
    status = int(headers.split(b" ", 2)[1])
    length = int(fields.get(b"content-length", b"0"))
    while len(body) < length:
        chunk = client.recv(16384)
        assert chunk, "connection closed inside response body"
        body += chunk
    assert len(body) == length, (status, body)
    return status, fields, body


class Client:
    """One persistent HTTP/1.1 connection: several requests share a socket."""

    def __init__(self, port):
        self.sock = socket.create_connection(("127.0.0.1", port), timeout=3)

    def close(self):
        self.sock.close()

    def call(self, method, target, value=None, raw=None, content_type="application/json"):
        body = raw if raw is not None else (json.dumps(value).encode() if value is not None else b"")
        head = f"{method} {target} HTTP/1.1\r\nHost: localhost\r\nContent-Length: {len(body)}\r\n"
        if content_type and body:
            head += f"Content-Type: {content_type}\r\n"
        self.sock.sendall(head.encode() + b"\r\n" + body)
        status, fields, payload = read_response(self.sock)
        assert b"x-request-id" in fields, fields
        parsed = json.loads(payload) if payload else None
        return status, parsed


def start(executable, port, datafile):
    process = subprocess.Popen([str(executable), str(port), str(datafile)],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    deadline = time.monotonic() + 5
    while True:
        assert process.poll() is None, "todo server exited during startup"
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.1):
                return process
        except ConnectionRefusedError:
            if time.monotonic() > deadline:
                process.kill()
                raise AssertionError("todo server did not start")
            time.sleep(0.02)


def stop(process):
    process.terminate()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()


def check_openapi(spec):
    # The document comes from the routes and the registrations: `completed` is `done` on the wire.
    assert spec["openapi"] == "3.1.0" and spec["info"]["title"] == "SQLite Todo API", spec["info"]
    paths = spec["paths"]
    collection = paths.get("/todos") or paths.get("/todos/")
    assert collection is not None, sorted(paths)
    item = paths["/todos/{id}"]
    assert set(item) >= {"get", "patch", "delete"}, sorted(item)
    assert collection["get"]["summary"].startswith("List todos")
    assert collection["get"]["responses"]["200"]["content"]["application/json"]["schema"]["type"] == "array"
    todo = collection["get"]["responses"]["200"]["content"]["application/json"]["schema"]["items"]
    assert "done" in todo["properties"] and "completed" not in todo["properties"], todo
    created = collection["post"]
    assert created["requestBody"]["required"] is True
    create_input = created["requestBody"]["content"]["application/json"]["schema"]
    assert create_input["required"] == ["title"], create_input
    assert set(create_input["properties"]) == {"title", "done"}, create_input
    assert create_input["properties"]["title"]["maxLength"] == 200
    assert create_input["properties"]["title"]["minLength"] == 1
    patch_input = item["patch"]["requestBody"]["content"]["application/json"]["schema"]
    assert "required" not in patch_input, patch_input
    assert set(patch_input["properties"]) == {"title", "done"}, patch_input
    assert item["delete"]["responses"]["204"] and "content" not in item["delete"]["responses"]["204"]
    assert item["get"]["responses"]["404"]["content"]["application/json"]["schema"]["type"] == "object"


def test_crud_and_persistence(executable):
    with tempfile.TemporaryDirectory(prefix="goose-sqlite-todos-") as directory:
        datafile = Path(directory) / "todos.db"
        port = free_port()
        process = start(executable, port, datafile)
        try:
            client = Client(port)

            status, item = client.call("POST", "/todos", {"title": "write the SQLite layer"})
            assert status == 201 and item == {"id": 1, "title": "write the SQLite layer", "done": False}, item
            hostile = "x'); DROP TABLE todos; --"
            status, item = client.call("POST", "/todos", {"title": hostile, "done": True})
            assert status == 201 and item == {"id": 2, "title": hostile, "done": True}, item
            # The declared name is not a key any more: `completed` is an unknown key.
            status, error = client.call("POST", "/todos", {"title": "old name", "completed": True})
            assert status == 422 and error["error"]["code"] == "invalid_payload", error
            assert "completed" in error["error"]["message"], error

            status, items = client.call("GET", "/todos")
            assert status == 200 and [t["id"] for t in items] == [1, 2], items
            assert items[1]["title"] == hostile, items

            status, item = client.call("GET", "/todos/1")
            assert status == 200 and item["title"] == "write the SQLite layer", item
            status, error = client.call("GET", "/todos/999")
            assert status == 404 and error["error"]["code"] == "todo_not_found", error
            status, error = client.call("GET", "/todos/abc")
            assert status == 422 and error["error"]["code"] == "invalid_param", error

            status, item = client.call("PATCH", "/todos/1", {"done": True})
            assert status == 200 and item == {"id": 1, "title": "write the SQLite layer", "done": True}, item
            status, item = client.call("PATCH", "/todos/1", {"title": "renamed"})
            assert status == 200 and item["title"] == "renamed" and item["done"] is True, item
            status, error = client.call("PATCH", "/todos/1", {"completed": False})
            assert status == 422 and error["error"]["code"] == "invalid_payload", error
            status, error = client.call("PATCH", "/todos/1", {"colour": "red"})
            assert status == 422 and error["error"]["code"] == "invalid_payload", error
            status, error = client.call("PATCH", "/todos/999", {"done": True})
            assert status == 404, error

            status, error = client.call("POST", "/todos", {"title": ""})
            assert status == 422 and error["error"]["code"] == "invalid_payload", error
            status, error = client.call("POST", "/todos", {"title": "", "done": "wrong", "extra": 1})
            assert status == 422 and error["truncated"] is False, error
            details = {(tuple(issue["loc"]), issue["type"]) for issue in error["detail"]}
            assert details == {(("body", "done"), "bool_type"),
                               (("body", "extra"), "extra_forbidden"),
                               (("body", "title"), "string_too_short")}, error
            status, error = client.call("POST", "/todos", {"title": "x" * 201})
            assert status == 422 and error["error"]["code"] == "invalid_payload", error
            status, error = client.call("POST", "/todos", raw=b"{not json")
            assert status == 400 and error["error"]["code"] == "invalid_json", error

            status, _ = client.call("DELETE", "/todos/2")
            assert status == 204, status
            status, error = client.call("GET", "/todos/2")
            assert status == 404, error
            status, error = client.call("DELETE", "/todos/2")
            assert status == 404, error

            # The document is fetched on the same keep-alive connection, framed by Content-Length.
            status, spec = client.call("GET", "/openapi.json")
            assert status == 200, spec
            check_openapi(spec)
            client.close()
        finally:
            stop(process)

        # A second process over the same file sees the committed rows, and ids keep counting.
        port = free_port()
        process = start(executable, port, datafile)
        try:
            client = Client(port)
            status, items = client.call("GET", "/todos")
            assert status == 200 and items == [{"id": 1, "title": "renamed", "done": True}], items
            status, item = client.call("POST", "/todos", {"title": "after restart"})
            assert status == 201 and item["id"] == 2, item
            client.close()
        finally:
            stop(process)
    print("SQLite Todo example tests passed: CRUD, validation, keep-alive framing, restart persistence")


if __name__ == "__main__":
    executable = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[2] / "build/sqlite-todos"
    test_crud_and_persistence(executable)
