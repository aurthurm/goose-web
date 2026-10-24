#!/usr/bin/env python3
"""TCP layer over real sockets: echo with fragmented and large payloads, concurrent clients, slot reuse and
rejection, backpressure (a client that does not read keeps the server's reads paused), idle timeout, line and
length-prefixed framing, client connect success and refusal, the proxy and chat examples, and graceful shutdown.
Usage: tcp.py BUILD_DIR   (BUILD_DIR holds the tcp fixture and the tcp-proxy and tcp-chat examples)."""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import os
import random
import signal
import socket
import struct
import subprocess
import sys
import threading
import time

ROOT = Path(__file__).resolve().parents[2]
BUILD = ROOT / "build"
WELCOME = b"Welcome. /nick NAME to rename, /quit to leave.\n"


def free_port():
    with socket.socket() as reservation:
        reservation.bind(("127.0.0.1", 0))
        return reservation.getsockname()[1]


def launch(argv, port):
    """Starts a server and waits until its listener accepts. Returns the process."""
    process = subprocess.Popen([str(part) for part in argv], stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               text=True)
    deadline = time.monotonic() + 5
    while True:
        assert process.poll() is None, f"server exited during startup: {process.stdout.read()}"
        try:
            socket.create_connection(("127.0.0.1", port), timeout=1).close()
            break
        except ConnectionRefusedError:
            assert time.monotonic() < deadline, "server did not start"
            time.sleep(0.02)
    time.sleep(0.05)
    return process


def finish(process, sig=signal.SIGTERM):
    """Signals the server (if sig is given), waits for it, and returns (exit code, STATS dict, output)."""
    if sig is not None:
        process.send_signal(sig)
    out, _ = process.communicate(timeout=30)
    stats = {}
    for line in out.splitlines():
        if line.startswith("STATS "):
            for pair in line.split()[1:]:
                key, _, value = pair.partition("=")
                stats[key] = int(value)
    return process.returncode, stats, out


def connect(port, timeout=10):
    client = socket.create_connection(("127.0.0.1", port), timeout=timeout)
    client.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    return client


def read_exactly(client, count):
    data = b""
    while len(data) < count:
        chunk = client.recv(min(65536, count - len(data)))
        if not chunk:
            break
        data += chunk
    return data


def read_to_eof(client):
    data = b""
    while True:
        chunk = client.recv(65536)
        if not chunk:
            return data
        data += chunk


def test_echo(port):
    with connect(port) as client:
        client.sendall(b"hello world\n")
        assert read_exactly(client, 12) == b"hello world\n"
        # Fragmented sends: the server sees the message in pieces and still echoes all of it.
        message = bytes(random.Random(7).randrange(256) for _ in range(3000))
        for offset in range(0, len(message), 97):
            client.sendall(message[offset:offset + 97])
            time.sleep(0.0005)
        assert read_exactly(client, len(message)) == message
    print("echo: small and fragmented payloads ok")


def test_large_payload(port):
    payload = os.urandom(4 * 1024 * 1024)
    with connect(port, timeout=30) as client:
        sender = threading.Thread(target=client.sendall, args=(payload,))
        sender.start()
        echoed = read_exactly(client, len(payload))
        sender.join()
    assert echoed == payload, "4 MiB echo differs"
    print("echo: 4 MiB payload ok")


def test_many_clients(port):
    def session(index):
        with connect(port) as client:
            for line in range(20):
                text = f"client {index} line {line}\n".encode()
                client.sendall(text)
                assert read_exactly(client, len(text)) == text, f"client {index} line {line}"
        return index

    with ThreadPoolExecutor(max_workers=32) as pool:
        assert list(pool.map(session, range(64))) == list(range(64))
    print("echo: 64 concurrent clients x 20 lines ok")


def test_slot_reuse_and_rejection():
    port = free_port()
    process = launch([BUILD / "tcp", "echo", port, "conns=2"], port)
    # Sequential clients reuse the slots, and each new connection gets a new id.
    for index in range(300):
        with connect(port) as client:
            client.sendall(b"%d\n" % index)
            assert read_exactly(client, len(str(index)) + 1) == b"%d\n" % index
    # Two held connections fill the two slots; a third is refused, so it gets EOF without a reply.
    first, second = connect(port), connect(port)
    first.sendall(b"a\n")
    assert read_exactly(first, 2) == b"a\n"
    second.sendall(b"b\n")
    assert read_exactly(second, 2) == b"b\n"
    third = connect(port)
    assert read_to_eof(third) == b"", "a connection over the limit was served"
    third.close()
    first.close()
    second.close()
    code, stats, out = finish(process)
    assert code == 0, out
    assert stats["rejected"] >= 1, stats
    # accepted counts refused connections too; every served connection closed.
    assert stats["active"] == 0 and stats["closed"] + stats["rejected"] == stats["accepted"], stats
    print(f"slots: 300 sequential reuses and one rejection ok ({stats['accepted']} accepted)")


def test_backpressure():
    """A client sends 16 MiB and does not read. The server reads only until its queue reaches the high-water
    mark (half of 64 KiB), then pauses, so most of the payload stays unread until shutdown."""
    payload = os.urandom(16 * 1024 * 1024)
    port = free_port()
    process = launch([BUILD / "tcp", "echo", port, "queue=65536", "read=16384", "grace=20000"], port)
    client = socket.socket()
    client.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
    client.connect(("127.0.0.1", port))

    def send_all():
        try:
            client.sendall(payload)
        except OSError:
            pass

    sender = threading.Thread(target=send_all)
    sender.start()
    time.sleep(1.5)
    assert process.poll() is None
    process.send_signal(signal.SIGTERM)
    received = read_to_eof(client)
    sender.join(timeout=30)
    client.close()
    code, stats, out = finish(process, sig=None)
    assert code == 0, out
    read_by_server = stats["bytes_read"]
    assert read_by_server < len(payload) // 2, f"server read {read_by_server} bytes while the client did not read"
    assert len(received) == read_by_server, (len(received), read_by_server)
    assert received == payload[:len(received)], "echoed bytes differ from the sent prefix"
    print(f"backpressure: server read {read_by_server // 1024} KiB of 16 MiB while the client did not read; "
          f"all {len(received) // 1024} KiB echoed were intact")


def test_idle_timeout():
    port = free_port()
    process = launch([BUILD / "tcp", "echo", port, "idle=300"], port)
    with connect(port, timeout=5) as client:
        started = time.monotonic()
        assert read_to_eof(client) == b""
        assert time.monotonic() - started < 3, "idle connection was not closed"
    code, stats, out = finish(process)
    assert code == 0, out
    assert stats["timeouts"] == 1, stats
    print("idle timeout: an idle client was closed after 300 ms")


def test_lines(port):
    with connect(port) as client:
        client.sendall(b"hello\r\n")
        assert read_exactly(client, 12) == b"echo: hello\n"
        client.sendall(b"hel")
        time.sleep(0.05)
        client.sendall(b"lo\n")
        assert read_exactly(client, 12) == b"echo: hello\n"
        client.sendall(b"x" * 100 + b"\n")
        assert read_to_eof(client).endswith(b"too long\n")
    print("lines: split and CRLF lines ok; a line over 64 bytes closes the connection")


def test_frames(port):
    messages = (b"one", b"", b"three" * 50)
    wire = b"".join(struct.pack(">H", len(m)) + m for m in messages)
    with connect(port) as client:
        for index in range(len(wire)):
            client.sendall(wire[index:index + 1])
        assert read_exactly(client, len(wire)) == wire
        client.sendall(struct.pack(">H", 2000) + b"x" * 10)
        assert read_to_eof(client) == b""
    print("frames: byte-by-byte 2-byte-length frames echoed; a frame over 1000 bytes closes the connection")


def test_dial_success(echo_port):
    process = subprocess.Popen([str(BUILD / "tcp"), "dial", str(free_port()), str(echo_port)],
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    out, _ = process.communicate(timeout=30)
    assert process.returncode == 0, out
    assert "reply: PING" in out and "closed: 3" in out, out
    print("client: tcp_connect to a live server, PING round trip, application close ok")


def test_dial_refused():
    process = subprocess.Popen([str(BUILD / "tcp"), "dial", str(free_port()), str(free_port())],
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    out, _ = process.communicate(timeout=30)
    assert process.returncode == 0, out
    assert "closed: 5" in out, out
    print("client: tcp_connect to a closed port reports CONNECT_FAILED")


def test_shutdown_drain():
    port = free_port()
    process = launch([BUILD / "tcp", "echo", port, "grace=3000"], port)
    client = connect(port)
    client.sendall(b"abc")
    assert read_exactly(client, 3) == b"abc"
    process.send_signal(signal.SIGTERM)
    rest = read_to_eof(client)
    client.close()
    code, stats, out = finish(process, sig=None)
    assert code == 0, out
    assert rest == b"", rest
    assert stats["active"] == 0, stats
    print("shutdown: SIGTERM closed the open connection and the loop exited 0")


def test_proxy(echo_port):
    port = free_port()
    process = launch([BUILD / "tcp-proxy", port, "127.0.0.1", echo_port], port)
    payload = os.urandom(2 * 1024 * 1024)
    with connect(port, timeout=30) as client:
        sender = threading.Thread(target=client.sendall, args=(payload,))
        sender.start()
        assert read_exactly(client, len(payload)) == payload, "proxied bytes differ"
        sender.join()
    code, _, out = finish(process)
    assert code == 0, out
    print("proxy: 2 MiB round trip through an upstream connection, both ways")


def test_proxy_refused():
    port = free_port()
    process = launch([BUILD / "tcp-proxy", port, "127.0.0.1", free_port()], port)
    with connect(port) as client:
        client.sendall(b"hello")
        # The proxy closes with the client's bytes still unread, so the kernel may send a reset instead of EOF.
        try:
            assert read_to_eof(client) == b""
        except ConnectionResetError:
            pass
    code, _, out = finish(process)
    assert code == 0, out
    print("proxy: a refused upstream closes the client")


def test_chat():
    port = free_port()
    process = launch([BUILD / "tcp-chat", port], port)
    alice = connect(port)
    assert read_exactly(alice, len(WELCOME)) == WELCOME
    bob = connect(port)
    assert read_exactly(bob, len(WELCOME)) == WELCOME
    assert read_exactly(alice, len("* guest1 joined\n")) == b"* guest1 joined\n"
    alice.sendall(b"/nick alice\n")
    bob.sendall(b"/nick bob\n")
    bob.sendall(b"hi there\n")
    assert read_exactly(alice, len("bob: hi there\n")) == b"bob: hi there\n"
    alice.sendall(b"hello\n")
    assert read_exactly(bob, len("alice: hello\n")) == b"alice: hello\n"
    bob.sendall(b"/quit\n")
    assert read_to_eof(bob) == b""
    assert read_exactly(alice, len("* bob left\n")) == b"* bob left\n"
    alice.close()
    code, _, out = finish(process)
    assert code == 0, out
    print("chat: join, nicknames, broadcast, /quit notices ok")


def main():
    global BUILD
    if len(sys.argv) > 1:
        BUILD = Path(sys.argv[1]).resolve()
    echo_port, lines_port, frames_port = free_port(), free_port(), free_port()
    echo = launch([BUILD / "tcp", "echo", echo_port], echo_port)
    lines = launch([BUILD / "tcp", "lines", lines_port], lines_port)
    frames = launch([BUILD / "tcp", "frames", frames_port], frames_port)
    try:
        test_echo(echo_port)
        test_large_payload(echo_port)
        test_many_clients(echo_port)
        test_lines(lines_port)
        test_frames(frames_port)
        test_dial_success(echo_port)
        test_dial_refused()
        test_proxy(echo_port)
        test_proxy_refused()
        test_chat()
    finally:
        for process in (echo, lines, frames):
            process.send_signal(signal.SIGTERM)
            process.communicate(timeout=30)
    test_slot_reuse_and_rejection()
    test_backpressure()
    test_idle_timeout()
    test_shutdown_drain()
    print("TCP integration tests passed")


if __name__ == "__main__":
    main()
