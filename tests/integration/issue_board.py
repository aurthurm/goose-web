#!/usr/bin/env python3
"""Real socket coverage for the modular SQLite issue board example."""
from pathlib import Path
import json
import os
import socket
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor
import time


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


class Client:
    def __init__(self, port):
        self.sock = socket.create_connection(("127.0.0.1", port), timeout=3)

    def close(self):
        self.sock.close()

    def call(self, method, target, value=None):
        body = json.dumps(value).encode() if value is not None else b""
        head = f"{method} {target} HTTP/1.1\r\nHost: localhost\r\nContent-Length: {len(body)}\r\n"
        if body:
            head += "Content-Type: application/json\r\n"
        self.sock.sendall(head.encode() + b"\r\n" + body)
        data = b""
        while b"\r\n\r\n" not in data:
            chunk = self.sock.recv(16384)
            assert chunk, "connection closed before response headers"
            data += chunk
        headers, payload = data.split(b"\r\n\r\n", 1)
        fields = {k.lower(): v for k, v in (line.split(b": ", 1) for line in headers.split(b"\r\n")[1:])}
        status = int(headers.split(b" ", 2)[1])
        length = int(fields.get(b"content-length", b"0"))
        while len(payload) < length:
            chunk = self.sock.recv(16384)
            assert chunk, "connection closed before response body completed"
            payload += chunk
        assert b"x-request-id" in fields, fields
        assert b"x-content-type-options" in fields, fields
        self.last_headers = fields
        if not length:
            parsed = None
        else:
            try:
                parsed = json.loads(payload[:length])
            except json.JSONDecodeError:
                parsed = payload[:length].decode()
        return status, parsed


def start(binary, db=None, board_settings=True, cwd=None, workers=2):
    port = free_port()
    env = {key: value for key, value in os.environ.items() if not key.startswith("BOARD_")}
    env.pop("GOOSE_WEB_WORKERS", None)
    if board_settings:
        env["BOARD_DB_FILE"] = str(db)
        env["BOARD_TITLE"] = "Issue Board Integration"
    proc = subprocess.Popen([str(Path(binary).resolve()), "--port", str(port), "--workers", str(workers)],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=env, cwd=cwd)
    deadline = time.monotonic() + 8
    while proc.poll() is None and time.monotonic() < deadline:
        try:
            socket.create_connection(("127.0.0.1", port), timeout=0.1).close()
            return proc, port
        except OSError:
            time.sleep(0.03)
    proc.kill()
    proc.wait()
    raise AssertionError("issue board server failed to start")


def stop(proc):
    proc.terminate()
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill(); proc.wait()


def create_project(port, number):
    client = Client(port)
    try:
        return client.call("POST", "/projects", {"name": f"Parallel {number}"})
    finally:
        client.close()


def test(binary):
    with tempfile.TemporaryDirectory(prefix="goose-issue-board-") as tmp:
        db = Path(tmp) / "board.db"
        proc, port = start(binary, db)
        try:
            c = Client(port)
            code, project = c.call("POST", "/projects", {"name": "Platform"})
            assert code == 201 and project["id"] == 1 and project["description"] == "", project
            code, project = c.call("GET", "/projects/1")
            assert code == 200 and project["name"] == "Platform", project
            code, project = c.call("PATCH", "/projects/1", {"description": "Core services"})
            assert code == 200 and project["description"] == "Core services", project
            code, issue = c.call("POST", "/issues", {"project_id": 1, "title": "Add health checks"})
            assert code == 201 and issue["status"] == "open", issue
            code, _ = c.call("PATCH", "/issues/1", {"status": "in_progress"})
            assert code == 200
            code, issue = c.call("PATCH", "/issues/1", {"status": "closed"})
            assert code == 200 and issue["status"] == "closed"
            code, error = c.call("PATCH", "/issues/1", {"status": "in_progress"})
            assert code == 409 and error["error"]["code"] == "invalid_transition", error
            code, error = c.call("POST", "/projects", {"name": "", "unknown": True})
            assert code == 422 and len(error["detail"]) >= 2, error
            code, error = c.call("POST", "/issues", {"project_id": 99, "title": "orphan"})
            assert code == 404 and error["error"]["code"] == "project_not_found", error
            code, error = c.call("POST", "/issues", {"title": "Missing project ID"})
            assert code == 422 and error["error"]["code"] == "invalid_payload", error
            code, error = c.call("GET", "/issues/999")
            assert code == 404 and error["error"]["code"] == "issue_not_found", error
            code, issues = c.call("GET", "/issues")
            assert code == 200 and len(issues) == 1 and issues[0]["id"] == 1, issues
            code, temporary = c.call("POST", "/projects", {"name": "Temporary"})
            assert code == 201, temporary
            code, child = c.call("POST", "/issues", {"project_id": temporary["id"], "title": "Cascade check"})
            assert code == 201, child
            code, _ = c.call("DELETE", f"/projects/{temporary['id']}")
            assert code == 204
            code, error = c.call("GET", f"/projects/{temporary['id']}")
            assert code == 404 and error["error"]["code"] == "project_not_found", error
            code, error = c.call("GET", f"/issues/{child['id']}")
            assert code == 404 and error["error"]["code"] == "issue_not_found", error
            code, temporary_issue = c.call("POST", "/issues", {"project_id": 1, "title": "Temporary issue"})
            assert code == 201
            code, _ = c.call("DELETE", f"/issues/{temporary_issue['id']}")
            assert code == 204
            code, error = c.call("GET", f"/issues/{temporary_issue['id']}")
            assert code == 404 and error["error"]["code"] == "issue_not_found", error
            c.close()
            with ThreadPoolExecutor(max_workers=4) as pool:
                results = list(pool.map(lambda n: create_project(port, n), range(4)))
            assert all(status == 201 for status, _ in results), results
            assert len({project["id"] for _, project in results}) == 4, results
            c = Client(port)
            code, spec = c.call("GET", "/openapi.json")
            assert code == 200 and spec["openapi"] == "3.1.0" and spec["info"]["title"] == "Issue Board Integration", spec
            assert "/projects" in spec["paths"] and "/issues" in spec["paths"]
            code, docs = c.call("GET", "/docs")
            assert code == 200 and "swagger-ui" in docs, docs
            csp = c.last_headers[b"content-security-policy"].decode()
            assert "https://cdn.jsdelivr.net" in csp and "'unsafe-inline'" in csp, csp
            c.close()
        finally:
            stop(proc)
        proc, port = start(binary, db)
        try:
            c = Client(port)
            code, issue = c.call("GET", "/issues/1")
            assert code == 200 and issue["status"] == "closed", issue
            code, projects = c.call("GET", "/projects")
            assert code == 200 and projects[0]["name"] == "Platform" and projects[0]["description"] == "Core services", projects
            c.close()
        finally:
            stop(proc)
    print("Issue Board integration tests passed")


def test_default_settings(binary):
    with tempfile.TemporaryDirectory(prefix="goose-issue-board-defaults-") as tmp:
        build = Path(tmp) / "build"
        build.mkdir()
        proc, port = start(binary, cwd=tmp, board_settings=False, workers=1)
        try:
            client = Client(port)
            code, spec = client.call("GET", "/openapi.json")
            assert code == 200 and spec["info"]["title"] == "Issue Board API", spec
            code, project = client.call("POST", "/projects", {"name": "Default settings"})
            assert code == 201 and project["id"] == 1, project
            client.close()
        finally:
            stop(proc)
        assert (build / "issue-board.db").is_file()


if __name__ == "__main__":
    binary = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[2] / "build/issue-board"
    test(binary)
    test_default_settings(binary)
