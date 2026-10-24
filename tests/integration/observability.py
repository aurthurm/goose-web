#!/usr/bin/env python3
"""Live checks for the observability middleware over real sockets: JSON request logs, trusted-proxy client
addresses (including a spoofing peer), ETag and If-None-Match, load shedding, the per-route body cap and the
route pattern in the log. Usage: observability.py <path to the observability fixture>."""
from pathlib import Path
import json
import re
import socket
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
HELLO_TAG = b'"LPJNul-wow4m6Dsqxbning"'


def read_response(client, head=False):
    # HTTP/1.1 connections persist by default, so frame by Content-Length (absent means no body).
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


def get(path, extra=b""):
    return b"GET " + path + b" HTTP/1.1\r\nHost: x\r\n" + extra + b"\r\n"


def start(executable, *arguments):
    with socket.socket() as reservation:
        reservation.bind(("127.0.0.1", 0))
        port = reservation.getsockname()[1]
    process = subprocess.Popen([str(executable), str(port), *arguments], stdout=subprocess.PIPE, cwd=ROOT)
    deadline = time.monotonic() + 3
    while True:
        if process.poll() is not None:
            raise AssertionError("observability server exited during startup")
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.1):
                break
        except ConnectionRefusedError:
            if time.monotonic() > deadline:
                raise
            time.sleep(0.02)
    return process, port


def stop(process):
    """Stops the server and returns its stdout, parsed as JSON log lines (other lines are ignored)."""
    process.terminate()
    output, _ = process.communicate(timeout=5)
    lines = []
    for raw in output.splitlines():
        if raw.startswith(b"{"):
            lines.append(json.loads(raw))
    return lines


def check_etag(port):
    status, fields, body = exchange(port, get(b"/hello"))
    assert status == 200 and body == b"hello" and fields[b"ETag"] == HELLO_TAG, (status, fields)
    status, fields, body = exchange(port, get(b"/hello", b"If-None-Match: " + HELLO_TAG + b"\r\n"))
    assert status == 304 and body == b"" and b"Content-Type" not in fields and fields[b"ETag"] == HELLO_TAG, fields
    status, _, body = exchange(port, get(b"/hello", b'If-None-Match: W/"x", ' + HELLO_TAG + b"\r\n"))
    assert status == 304 and body == b"", status
    status, _, body = exchange(port, get(b"/hello", b'If-None-Match: "other"\r\n'))
    assert status == 200 and body == b"hello", status
    status, _, body = exchange(port, b"HEAD /hello HTTP/1.1\r\nHost: x\r\nIf-None-Match: *\r\n\r\n")
    assert status == 304 and body == b"", status


def check_proxies(port):
    status, _, body = exchange(port, get(b"/ip", b"X-Forwarded-For: 198.51.100.7, 10.1.1.1\r\n"))
    assert status == 200 and body == b"198.51.100.7", body
    # A peer outside the trusted networks is not believed: 127.0.0.2 is loopback but not trusted here.
    status, _, body = exchange(port, get(b"/ip", b"X-Forwarded-For: 10.0.0.1\r\n"), source=("127.0.0.2", 0))
    assert status == 200 and body == b"127.0.0.2", body
    status, _, body = exchange(port, get(b"/ip"))
    assert status == 200 and body == b"127.0.0.1", body


def check_shedding(port):
    status, fields, body = exchange(port, get(b"/limited"))
    assert status == 503 and fields[b"Retry-After"] == b"3", (status, fields)
    assert json.loads(body)["error"]["code"] == "overloaded", body
    status, _, body = exchange(port, get(b"/hello"))
    assert status == 200 and body == b"hello", "unshed route must still answer"
    status, _, body = exchange(port, get(b"/pressure"))
    pressure = json.loads(body)
    assert status == 200 and pressure["active"] >= 1 and pressure["max_clients"] == 64, pressure
    assert pressure["pool_bytes_max"] == 8388608 and pressure["max_queued_events"] == 64, pressure


def check_body_limit(port):
    def post(body):
        raw = (b"POST /small HTTP/1.1\r\nHost: x\r\nContent-Length: " + str(len(body)).encode() + b"\r\n\r\n" + body)
        return exchange(port, raw)

    status, _, body = post(b"123456789")
    assert status == 413 and json.loads(body)["error"]["code"] == "payload_too_large", body
    status, _, body = post(b"12345678")
    assert status == 200 and body == b"got 8", body


def check_logs(lines):
    timestamp = re.compile(r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$")
    assert lines, "no JSON log lines were written"
    for entry in lines:
        assert set(entry) >= {"ts", "level", "request_id", "method", "path", "route", "status", "bytes",
                              "duration_us", "peer", "client_ip", "user_agent"}, entry
        assert timestamp.match(entry["ts"]), entry["ts"]
        assert isinstance(entry["request_id"], int) and entry["duration_us"] >= 0, entry
        assert "pid" not in entry, "single-process server must not log a pid"
    by_path = {}
    for entry in lines:
        by_path.setdefault(entry["path"], []).append(entry)

    hello = by_path["/hello"][0]
    assert hello["route"] == "/hello" and hello["status"] == 200 and hello["bytes"] == 5, hello
    assert hello["level"] == "info" and hello["method"] == "GET" and hello["peer"] == "127.0.0.1", hello

    forwarded = [e for e in by_path["/ip"] if e["client_ip"] == "198.51.100.7"][0]
    assert forwarded["peer"] == "127.0.0.1" and forwarded["status"] == 200, forwarded
    spoofed = [e for e in by_path["/ip"] if e["peer"] == "127.0.0.2"][0]
    assert spoofed["client_ip"] == "127.0.0.2", spoofed

    # The query string is not logged, and the route pattern is the matched one (not the concrete path).
    user = by_path["/users/42"][0]
    assert user["route"] == "/users/:id" and user["status"] == 200, user
    assert all("secret" not in json.dumps(e) for e in lines)

    missing = [e for e in lines if e["status"] == 404][0]
    assert missing["route"] is None and missing["level"] == "warn", missing

    shed = [e for e in lines if e["status"] == 503][0]
    assert shed["route"] == "/limited" and shed["level"] == "error", shed

    agent = [e for e in lines if e["user_agent"].startswith("Mozilla")][0]
    # Quotes and backslashes survive JSON escaping; the two UTF-8 bytes become "??"; the value is cut at 128.
    assert agent["user_agent"] == 'Mozilla "x" \\ y ??' + "a" * 110, agent


def test_observability(executable):
    process, port = start(executable)
    try:
        check_etag(port)
        check_proxies(port)
        check_shedding(port)
        check_body_limit(port)
        exchange(port, get(b"/users/42?secret=hunter2"))
        exchange(port, get(b"/missing"))
        agent = b'Mozilla "x" \\ y \xc3\xa9' + b"a" * 200
        exchange(port, get(b"/hello", b"User-Agent: " + agent + b"\r\n"))
        check_logs(stop(process))
    finally:
        if process.poll() is None:
            process.kill()


def test_worker_pids(executable):
    process, port = start(executable, "workers")
    try:
        for _ in range(4):
            status, _, _ = exchange(port, get(b"/hello"))
            assert status == 200
        lines = stop(process)
    finally:
        if process.poll() is None:
            process.kill()
    assert lines, "workers wrote no log lines"
    assert all(isinstance(entry.get("pid"), int) and entry["pid"] > 0 for entry in lines), lines[:2]


if __name__ == "__main__":
    fixture = Path(sys.argv[1])
    test_observability(fixture)
    test_worker_pids(fixture)
    print("Observability integration tests passed: JSON logs, trusted proxies, ETag, shedding, body_limit, worker pids")
