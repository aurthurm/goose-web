#!/usr/bin/env python3
"""Standalone runtime checks; builds its own fixture with GOOSE or /opt/goose/goose."""
import os
from pathlib import Path
import signal
import socket
import subprocess
import time

ROOT = Path(__file__).resolve().parents[2]
BUILD = ROOT / "build"


def connect(port):
    return socket.create_connection(("127.0.0.1", port), timeout=2)


def response(client):
    data = b""
    while True:
        try:
            chunk = client.recv(4096)
        except ConnectionResetError:
            break  # closing a capped request can discard unread trailing bytes
        if not chunk:
            break
        data += chunk
    return data


def run(mode, operation):
    with socket.socket() as reservation:
        reservation.bind(("127.0.0.1", 0))
        port = reservation.getsockname()[1]
    process = subprocess.Popen([str(BUILD / "runtime"), str(port), mode], stdout=subprocess.PIPE, text=True)
    try:
        deadline = time.monotonic() + 3
        while True:
            assert process.poll() is None, "fixture exited at startup"
            try:
                with connect(port):
                    pass
                break
            except ConnectionRefusedError:
                assert time.monotonic() < deadline
                time.sleep(0.01)
        time.sleep(0.03)  # let the readiness connection close
        operation(port, process)
        out, _ = process.communicate(timeout=3)
        assert process.returncode == 0, out
        row = next(line for line in out.splitlines() if line.startswith("STATS "))
        return list(map(int, row.split()[1:]))
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()


def finite(port, process):
    with connect(port) as client:
        client.sendall(b"GET / HTTP/1.1\r\nHost: x\r\n\r\n")
        assert b"200 OK" in response(client)


def drain(port, process):
    with connect(port) as pending, connect(port) as stop:
        pending.sendall(b"GET / HTTP/1.1\r\nHost:")
        stop.sendall(b"GET /stop HTTP/1.1\r\nHost: x\r\n\r\n")
        assert b"200 OK" in response(stop)
        time.sleep(0.03)
        pending.sendall(b" x\r\n\r\n")
        assert b"200 OK" in response(pending)


def grace(port, process):
    with connect(port) as pending:
        pending.sendall(b"GET /")
        time.sleep(0.03)
        started = time.monotonic()
        process.send_signal(signal.SIGTERM)
        assert response(pending) == b""
        assert 0.25 < time.monotonic() - started < 1.5


def limits(port, process):
    with connect(port) as idle, connect(port) as second:
        idle.sendall(b"GET /")
        second.sendall(b"GET /")
        time.sleep(0.03)
        with connect(port) as rejected:
            assert response(rejected) == b""
        assert response(idle) == b"" and response(second) == b""
    with connect(port) as oversized:
        oversized.sendall(b"x" * 128)
        assert b"431 " in response(oversized)
    with connect(port) as oversized_body:
        oversized_body.sendall(b"POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 100\r\n\r\n" + b"x" * 100)
        assert b"413 " in response(oversized_body)
    process.send_signal(signal.SIGINT)


def deadline_limit(port, process):
    with connect(port) as pending:
        pending.sendall(b"GET /")
        start = time.monotonic()
        assert response(pending) == b""
        assert time.monotonic() - start < 0.4, "poll interval delayed read timeout"
    process.send_signal(signal.SIGTERM)


def main():
    BUILD.mkdir(exist_ok=True)
    env = dict(os.environ, GOOSE_HOME=str(BUILD / "cache"))
    subprocess.run([os.environ.get("GOOSE", "/opt/goose/goose"), "build", str(ROOT / "tests/fixtures/runtime.goose"),
                    "--debug", "-o", str(BUILD / "runtime")], env=env, cwd=ROOT, check=True)
    stats = run("deadline", deadline_limit)
    assert stats[3] == 1, stats
    stats = run("finite", finite)
    assert stats[1] == 1 and stats[5] > 0 and stats[6] > 0, stats
    stats = run("drain", drain)
    assert stats[1] == 2 and stats[4] == 0, stats
    stats = run("grace", grace)
    assert stats[4] == 1, stats
    stats = run("limits", limits)
    assert stats[2] >= 1 and stats[3] == 2 and stats[1] == 2, stats
    print("Runtime tests passed: validation, lifecycle, metrics, limits, drain, grace, SIGINT/SIGTERM")


if __name__ == "__main__":
    main()
