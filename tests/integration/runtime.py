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
BIG_BODY = bytes(i % 251 for i in range(1048576))


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


class Wire:
    """Reads framed responses from a persistent socket, keeping pipelined leftovers."""

    def __init__(self, sock):
        self.sock = sock
        self.buf = b""

    def response(self):
        while b"\r\n\r\n" not in self.buf:
            self.fill()
        head, self.buf = self.buf.split(b"\r\n\r\n", 1)
        lines = head.split(b"\r\n")
        status = int(lines[0].split(b" ")[1])
        fields = {key.lower(): value for key, value in (line.split(b": ", 1) for line in lines[1:])}
        length = int(fields.get(b"content-length", b"0"))
        while len(self.buf) < length:
            self.fill()
        body, self.buf = self.buf[:length], self.buf[length:]
        return status, fields, body

    def fill(self):
        chunk = self.sock.recv(65536)
        assert chunk, "connection closed before the response was complete"
        self.buf += chunk

    def closed(self, wait=0.5):
        # True when the peer closes within `wait` seconds; a still-open socket reports False.
        self.sock.settimeout(wait)
        try:
            chunk = self.sock.recv(4096)
        except socket.timeout:
            return False
        finally:
            self.sock.settimeout(2)
        if chunk:
            self.buf += chunk
            return False
        return True


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


def keepalive(port, process):
    # Two sequential requests, a 1 MiB body, then a parser error, all on one socket.
    with connect(port) as client:
        wire = Wire(client)
        client.sendall(b"GET /a HTTP/1.1\r\nHost: x\r\n\r\n")
        status, fields, body = wire.response()
        assert status == 200 and body == b"/a" and b"connection" not in fields
        client.sendall(b"GET /b HTTP/1.1\r\nHost: x\r\n\r\n")
        status, fields, body = wire.response()
        assert status == 200 and body == b"/b"
        # A full 1 MiB body must arrive intact and keep the connection usable.
        client.sendall(b"GET /big HTTP/1.1\r\nHost: x\r\n\r\n")
        status, fields, body = wire.response()
        assert status == 200 and fields[b"content-length"] == b"1048576" and body == BIG_BODY
        client.sendall(b"GET / HTTP/1.1\r\n\r\n")  # missing Host: a parser error closes the connection
        status, fields, _ = wire.response()
        assert status == 400 and fields[b"connection"] == b"close"
        assert wire.closed()
    process.send_signal(signal.SIGINT)


def pipelined(port, process):
    # Two requests in one send are answered in order; the second asks to close.
    with connect(port) as client:
        client.sendall(b"GET /first HTTP/1.1\r\nHost: x\r\n\r\n"
                       b"GET /second HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
        wire = Wire(client)
        first = wire.response()
        second = wire.response()
        assert first[0] == 200 and first[2] == b"/first" and b"connection" not in first[1]
        assert second[0] == 200 and second[2] == b"/second" and second[1][b"connection"] == b"close"
        assert wire.closed()
    process.send_signal(signal.SIGINT)


def connection_tokens(port, process):
    # Connection is a case-insensitive token list, and close wins over keep-alive.
    with connect(port) as client:
        client.sendall(b"GET /a HTTP/1.1\r\nHost: x\r\nConnection: Keep-Alive, CLOSE\r\n\r\n")
        wire = Wire(client)
        status, fields, body = wire.response()
        assert status == 200 and fields[b"connection"] == b"close" and wire.closed()
    with connect(port) as client:
        # HTTP/1.0 persists only when the client asks; otherwise the server closes.
        client.sendall(b"GET /b HTTP/1.0\r\nHost: x\r\n\r\n")
        wire = Wire(client)
        status, fields, body = wire.response()
        assert status == 200 and fields[b"connection"] == b"close" and wire.closed()
    with connect(port) as client:
        client.sendall(b"GET /c HTTP/1.0\r\nHost: x\r\nConnection: keep-alive\r\n\r\n")
        wire = Wire(client)
        status, fields, body = wire.response()
        assert status == 200 and body == b"/c" and fields[b"connection"] == b"keep-alive"
        assert not wire.closed()
        client.sendall(b"GET /d HTTP/1.0\r\nHost: x\r\nConnection: close\r\n\r\n")
        status, fields, body = wire.response()
        assert body == b"/d" and fields[b"connection"] == b"close" and wire.closed()
    process.send_signal(signal.SIGINT)


def idle_timeout(port, process):
    # The fixture's idle limit is 150 ms: the server closes silently, with no 408 bytes.
    with connect(port) as client:
        client.sendall(b"GET /a HTTP/1.1\r\nHost: x\r\n\r\n")
        wire = Wire(client)
        assert wire.response()[0] == 200
        assert wire.closed(wait=1.5) and wire.buf == b""
    process.send_signal(signal.SIGINT)


def per_connection_limit(port, process):
    # max_requests_per_connection=2: the second response is the last and says close.
    with connect(port) as client:
        client.sendall(b"GET /a HTTP/1.1\r\nHost: x\r\n\r\n")
        wire = Wire(client)
        status, fields, body = wire.response()
        assert status == 200 and b"connection" not in fields
        client.sendall(b"GET /b HTTP/1.1\r\nHost: x\r\n\r\n")
        status, fields, body = wire.response()
        assert status == 200 and body == b"/b" and fields[b"connection"] == b"close"
        assert wire.closed()
    process.send_signal(signal.SIGINT)


def capped_body(port, process):
    # max_response_bytes=1024: an oversized body becomes a complete 500 and the connection stays usable.
    with connect(port) as client:
        wire = Wire(client)
        client.sendall(b"GET /big HTTP/1.1\r\nHost: x\r\n\r\n")
        status, fields, body = wire.response()
        assert status == 500 and b"response_too_large" in body
        client.sendall(b"GET /after HTTP/1.1\r\nHost: x\r\n\r\n")
        status, fields, body = wire.response()
        assert status == 200 and body == b"/after"
    process.send_signal(signal.SIGINT)


def keep_alive_disabled(port, process):
    # keep_alive=false restores one response per connection, even for HTTP/1.1.
    with connect(port) as client:
        client.sendall(b"GET /a HTTP/1.1\r\nHost: x\r\n\r\n")
        wire = Wire(client)
        status, fields, body = wire.response()
        assert status == 200 and fields[b"connection"] == b"close" and wire.closed()
    process.send_signal(signal.SIGINT)


def shutdown_keepalive(port, process):
    # An in-flight request finishes and closes; an idle keep-alive client is closed at once.
    with connect(port) as keeper, connect(port) as stop:
        wire = Wire(keeper)
        keeper.sendall(b"GET /a HTTP/1.1\r\nHost: x\r\n\r\n")
        assert wire.response()[0] == 200
        keeper.sendall(b"GET /x HTTP/1.1\r\nHost:")
        time.sleep(0.03)
        stop.sendall(b"GET /stop HTTP/1.1\r\nHost: x\r\n\r\n")
        status, fields, body = Wire(stop).response()
        assert status == 200 and fields[b"connection"] == b"close"
        time.sleep(0.03)
        keeper.sendall(b" x\r\n\r\n")
        status, fields, body = wire.response()
        assert status == 200 and body == b"/x" and fields[b"connection"] == b"close"
        assert wire.closed()


def many_idle(port, process):
    # max_clients=64 keep-alive connections stay open and idle, each having answered once. A 65th
    # client is refused, while a freed slot serves quick requests and the idle peers still answer.
    idle = []
    try:
        for _ in range(64):
            client = connect(port)
            client.sendall(b"GET /a HTTP/1.1\r\nHost: x\r\n\r\n")
            wire = Wire(client)
            assert wire.response()[0] == 200
            idle.append((client, wire))
        with connect(port) as refused:
            assert response(refused) == b""
        idle.pop()[0].close()
        time.sleep(0.03)
        started = time.monotonic()
        for n in range(20):
            with connect(port) as fast:
                fast.sendall(b"GET /fast%d HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n" % n)
                assert b"/fast%d" % n in response(fast)
        assert time.monotonic() - started < 2, "idle connections delayed other clients"
        for client, wire in idle:
            client.sendall(b"GET /b HTTP/1.1\r\nHost: x\r\n\r\n")
            status, fields, body = wire.response()
            assert status == 200 and body == b"/b"
    finally:
        for client, _ in idle:
            client.close()
    process.send_signal(signal.SIGINT)


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
    # Keep-alive: one socket carries four requests (three reused), then a parser error closes it.
    stats = run("keepalive", keepalive)
    assert stats[0] == 2 and stats[1] == 4 and stats[7] == 3, stats  # accepted includes the readiness probe
    stats = run("keepalive", pipelined)
    assert stats[0] == 2 and stats[1] == 2 and stats[7] == 1, stats
    stats = run("keepalive", connection_tokens)
    assert stats[1] == 4 and stats[4] == 0, stats
    stats = run("idle", idle_timeout)
    assert stats[1] == 1 and stats[3] == 0, stats
    stats = run("perconn", per_connection_limit)
    assert stats[1] == 2 and stats[7] == 1, stats
    stats = run("capped", capped_body)
    assert stats[1] == 2 and stats[4] == 0, stats
    stats = run("http1only", keep_alive_disabled)
    assert stats[1] == 1, stats
    stats = run("keepalive", shutdown_keepalive)
    assert stats[1] == 3 and stats[4] == 0, stats
    # 64 idle keep-alive peers (64 + 20 quick + 63 final responses); one refused client.
    stats = run("many", many_idle)
    assert stats[1] == 147 and stats[2] == 1 and stats[3] == 0, stats
    print("Runtime tests passed: validation, lifecycle, metrics, limits, drain, grace, SIGINT/SIGTERM, "
          "keep-alive, pipelining, Connection tokens, idle and per-connection limits, large bodies, "
          "many idle connections")


if __name__ == "__main__":
    main()
