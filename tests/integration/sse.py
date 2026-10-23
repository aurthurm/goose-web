#!/usr/bin/env python3
"""Server-sent events over real sockets: framing, channels, heartbeats, slow consumers, limits, shutdown."""
import signal
import socket
import subprocess
import sys
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CLOSE_EVENT = b"event: close\ndata: \n\n"


class Stream:
    """Reads one HTTP response and its chunks from a socket, keeping leftover bytes."""

    def __init__(self, sock):
        self.sock = sock
        self.buf = b""
        self.eof = False

    def _fill(self, timeout):
        self.sock.settimeout(timeout)
        chunk = self.sock.recv(65536)
        if not chunk:
            self.eof = True
            raise EOFError("peer closed the stream")
        self.buf += chunk

    def head(self):
        while b"\r\n\r\n" not in self.buf:
            self._fill(3)
        head, self.buf = self.buf.split(b"\r\n\r\n", 1)
        lines = head.split(b"\r\n")
        status = int(lines[0].split(b" ")[1])
        fields = {key.lower(): value for key, value in (line.split(b": ", 1) for line in lines[1:])}
        return status, fields

    def chunk(self, timeout=3):
        """Next chunk payload. An empty payload is the terminating chunk."""
        while b"\r\n" not in self.buf:
            self._fill(timeout)
        line, self.buf = self.buf.split(b"\r\n", 1)
        size = int(line, 16)
        while len(self.buf) < size + 2:
            self._fill(timeout)
        payload, trailer = self.buf[:size], self.buf[size:size + 2]
        assert trailer == b"\r\n", f"chunk not terminated by CRLF: {trailer!r}"
        self.buf = self.buf[size + 2:]
        return payload

    def exact(self, size, timeout=3):
        """The next size raw bytes, for plain (unchunked) bodies."""
        while len(self.buf) < size:
            self._fill(timeout)
        data, self.buf = self.buf[:size], self.buf[size:]
        return data

    def events(self, count, timeout=3):
        """Next `count` chunk payloads, failing on any terminating chunk."""
        out = []
        for _ in range(count):
            payload = self.chunk(timeout)
            assert payload, "stream ended before the expected event"
            out.append(payload)
        return out

    def silent(self, wait=0.3):
        """True when nothing arrives within wait seconds."""
        if self.buf:
            return False
        self.sock.settimeout(wait)
        try:
            chunk = self.sock.recv(4096)
        except socket.timeout:
            return True
        if not chunk:
            self.eof = True
            return False
        self.buf += chunk
        return False

    def rest(self, timeout=3):
        """Everything until the peer closes, with the leftover buffer."""
        data = self.buf
        self.buf = b""
        self.sock.settimeout(timeout)
        while True:
            try:
                chunk = self.sock.recv(65536)
            except socket.timeout:
                raise AssertionError("connection stayed open")
            if not chunk:
                break
            data += chunk
        self.eof = True
        return data


def connect(port):
    return socket.create_connection(("127.0.0.1", port), timeout=3)


def request(port, method, target, extra=b"", body=b"", version=b"HTTP/1.1"):
    sock = connect(port)
    payload = method + b" " + target + b" " + version + b"\r\nHost: x\r\n" + extra
    if body:
        payload += b"Content-Length: " + str(len(body)).encode() + b"\r\n"
    sock.sendall(payload + b"\r\n" + body)
    return sock


def open_stream(port, channel):
    sock = request(port, b"GET", b"/stream/%d" % channel)
    stream = Stream(sock)
    status, fields = stream.head()
    assert status == 200, status
    assert fields[b"content-type"] == b"text/event-stream", fields
    assert fields[b"transfer-encoding"] == b"chunked", fields
    assert b"content-length" not in fields, fields
    assert fields[b"cache-control"] == b"no-cache", fields
    return stream


def publish(port, channel, data):
    with request(port, b"POST", b"/publish/%d" % channel, extra=b"Connection: close\r\n", body=data) as sock:
        stream = Stream(sock)
        status, _ = stream.head()
        assert status == 200, status
        return int(stream.rest())


def stats(port):
    with request(port, b"GET", b"/stats", extra=b"Connection: close\r\n") as sock:
        stream = Stream(sock)
        status, _ = stream.head()
        assert status == 200
        text = stream.rest().decode()
    values = dict(part.split("=") for part in text.split())
    return {key: int(value) for key, value in values.items()}


def expect_close(stream):
    """Shutdown ends each stream with the close event, the terminating chunk, then EOF."""
    assert stream.chunk(timeout=5) == CLOSE_EVENT
    assert stream.chunk(timeout=5) == b""
    assert stream.rest(timeout=5) == b""


def stop(process):
    """Asks the fixture to shut down; streams must then receive their close events."""
    process.send_signal(signal.SIGTERM)


def plain_keep_alive(port):
    """A normal request on a persistent connection works while streams are open."""
    with connect(port) as sock:
        stream = Stream(sock)
        for _ in range(2):
            sock.sendall(b"GET /plain HTTP/1.1\r\nHost: x\r\n\r\n")
            status, fields = stream.head()
            assert status == 200 and fields[b"content-length"] == b"5", fields
            assert stream.exact(5) == b"plain"


def run(mode, operation):
    with socket.socket() as reservation:
        reservation.bind(("127.0.0.1", 0))
        port = reservation.getsockname()[1]
    process = subprocess.Popen([str(BUILD), str(port), mode], stdout=subprocess.PIPE, text=True)
    try:
        deadline = time.monotonic() + 3
        while True:
            assert process.poll() is None, "fixture exited at startup"
            try:
                connect(port).close()
                break
            except ConnectionRefusedError:
                assert time.monotonic() < deadline
                time.sleep(0.01)
        operation(port, process)
        out, _ = process.communicate(timeout=10)
        assert process.returncode == 0, out
        assert "sse fixture stopped" in out, out
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()


def default_mode(port, process):
    first = open_stream(port, 1)
    second = open_stream(port, 2)
    assert publish(port, 1, b"hello\nworld") == 1
    assert first.events(1) == [b"event: msg\ndata: hello\ndata: world\n\n"]
    assert second.silent(), "a channel-2 stream received a channel-1 event"
    assert publish(port, 2, b"two") == 1
    assert second.events(1) == [b"event: msg\ndata: two\n\n"]
    assert first.silent(), "a channel-1 stream received a channel-2 event"
    assert publish(port, 9, b"nobody") == 0
    plain_keep_alive(port)
    # Streams are not HTTP/1.0 or HEAD: each is refused with 400 and closed.
    with request(port, b"GET", b"/stream/1", extra=b"Connection: close\r\n", version=b"HTTP/1.0") as old:
        status, _ = Stream(old).head()
        assert status == 400, status
    with request(port, b"HEAD", b"/stream/1", extra=b"Connection: close\r\n") as head:
        status, _ = Stream(head).head()
        assert status == 400, status
    stats_now = stats(port)
    assert stats_now["connections"] >= 2 and stats_now["sse_active"] == 2, stats_now
    assert stats_now["sse_dropped"] == 0, stats_now
    stop(process)
    expect_close(first)
    expect_close(second)


def beat_mode(port, process):
    stream = open_stream(port, 1)
    assert stream.chunk(timeout=2) == b": ping\n\n"
    assert stream.chunk(timeout=2) == b": ping\n\n"
    stop(process)
    expect_close(stream)


def limit_mode(port, process):
    first = open_stream(port, 1)
    second = open_stream(port, 1)
    with request(port, b"GET", b"/stream/1", extra=b"Connection: close\r\n") as third:
        status, _ = Stream(third).head()
        assert status == 503, status
    assert publish(port, 1, b"fits") == 2
    assert first.events(1) == [b"event: msg\ndata: fits\n\n"]
    assert second.events(1) == [b"event: msg\ndata: fits\n\n"]
    stop(process)
    expect_close(first)
    expect_close(second)


def slow_mode(port, process):
    fast = open_stream(port, 3)
    # The slow stream never reads. Its small receive buffer makes the kernel queue fill quickly.
    slow_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    slow_sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
    slow_sock.settimeout(3)
    slow_sock.connect(("127.0.0.1", port))
    slow_sock.sendall(b"GET /stream/3 HTTP/1.1\r\nHost: x\r\n\r\n")
    slow = Stream(slow_sock)
    assert slow.head()[0] == 200

    received = []

    failures = []

    def drain():
        try:
            while len(received) < 200:
                received.append(fast.chunk(timeout=20))
        except Exception as error:  # reported below, after the reader has stopped
            failures.append(repr(error))

    reader = threading.Thread(target=drain)
    reader.start()
    with request(port, b"POST", b"/burst/3/200", extra=b"Connection: close\r\n") as sock:
        assert Stream(sock).head()[0] == 200
    deadline = time.monotonic() + 30
    while stats(port)["sse_dropped"] == 0:
        assert time.monotonic() < deadline, "slow stream was never dropped"
        time.sleep(0.05)
    reader.join(timeout=60)
    assert len(received) == 200, f"fast stream got {len(received)} of 200 events: {failures}"
    assert all(payload.startswith(b"event: burst\n") for payload in received)
    assert stats(port)["sse_dropped"] == 1
    # The dropped stream is closed without the terminating chunk: reading ends in EOF.
    tail = slow.rest(timeout=5)
    assert not tail.endswith(b"0\r\n\r\n"), "a dropped stream must not end cleanly"
    slow_sock.close()
    fresh = open_stream(port, 4)
    assert publish(port, 4, b"after") == 1
    assert fresh.events(1) == [b"event: msg\ndata: after\n\n"]
    stop(process)
    expect_close(fast)
    expect_close(fresh)


def main():
    global BUILD
    BUILD = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "build" / "sse_fixture"
    run("default", default_mode)
    run("beat", beat_mode)
    run("limit", limit_mode)
    run("slow", slow_mode)
    print("sse integration: ok")


if __name__ == "__main__":
    main()
