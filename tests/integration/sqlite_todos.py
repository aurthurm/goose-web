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


def test_crud_and_persistence(executable):
    with tempfile.TemporaryDirectory(prefix="goose-sqlite-todos-") as directory:
        datafile = Path(directory) / "todos.db"
        port = free_port()
        process = start(executable, port, datafile)
        try:
            client = Client(port)

            status, item = client.call("POST", "/todos", {"title": "write the SQLite layer"})
            assert status == 201 and item == {"id": 1, "title": "write the SQLite layer", "completed": False}, item
            hostile = "x'); DROP TABLE todos; --"
            status, item = client.call("POST", "/todos", {"title": hostile, "completed": True})
            assert status == 201 and item == {"id": 2, "title": hostile, "completed": True}, item

            status, items = client.call("GET", "/todos")
            assert status == 200 and [t["id"] for t in items] == [1, 2], items
            assert items[1]["title"] == hostile, items

            status, item = client.call("GET", "/todos/1")
            assert status == 200 and item["title"] == "write the SQLite layer", item
            status, error = client.call("GET", "/todos/999")
            assert status == 404 and error["error"]["code"] == "todo_not_found", error
            status, error = client.call("GET", "/todos/abc")
            assert status == 422 and error["error"]["code"] == "invalid_param", error

            status, item = client.call("PATCH", "/todos/1", {"completed": True})
            assert status == 200 and item == {"id": 1, "title": "write the SQLite layer", "completed": True}, item
            status, item = client.call("PATCH", "/todos/1", {"title": "renamed"})
            assert status == 200 and item["title"] == "renamed" and item["completed"] is True, item
            status, error = client.call("PATCH", "/todos/1", {"colour": "red"})
            assert status == 422 and error["error"]["code"] == "invalid_payload", error
            status, error = client.call("PATCH", "/todos/999", {"completed": True})
            assert status == 404, error

            status, error = client.call("POST", "/todos", {"title": ""})
            assert status == 422 and error["error"]["code"] == "invalid_payload", error
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
            client.close()
        finally:
            stop(process)

        # A second process over the same file sees the committed rows, and ids keep counting.
        port = free_port()
        process = start(executable, port, datafile)
        try:
            client = Client(port)
            status, items = client.call("GET", "/todos")
            assert status == 200 and items == [{"id": 1, "title": "renamed", "completed": True}], items
            status, item = client.call("POST", "/todos", {"title": "after restart"})
            assert status == 201 and item["id"] == 2, item
            client.close()
        finally:
            stop(process)
    print("SQLite Todo example tests passed: CRUD, validation, keep-alive framing, restart persistence")


if __name__ == "__main__":
    executable = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[2] / "build/sqlite-todos"
    test_crud_and_persistence(executable)
