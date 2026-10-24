#!/usr/bin/env python3
"""Pre-forked workers: concurrent clients across processes, a crashed worker is replaced, SIGTERM drains all,
aggregated stats, workers=0 means one worker per CPU, and the shared store works across workers (a global rate
limit, server-side sessions, and an event published in one worker reaching a stream held by another).
Usage: workers.py [path-to-the-workers-fixture]."""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import os
import re
import signal
import socket
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
BUILD = ROOT / "build"


def free_port():
    with socket.socket() as reservation:
        reservation.bind(("127.0.0.1", 0))
        return reservation.getsockname()[1]


def request(port, path):
    """One request on a fresh connection; the server closes it after the response (Connection: close)."""
    with socket.create_connection(("127.0.0.1", port), timeout=5) as client:
        client.sendall(f"GET {path} HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n".encode())
        data = b""
        while True:
            chunk = client.recv(65536)
            if not chunk:
                break
            data += chunk
    if not data:
        return None, b""
    head, _, body = data.partition(b"\r\n\r\n")
    return int(head.split(b" ")[1]), body


def send(port, method, path, body=b"", headers=()):
    """One request on a fresh connection with optional headers. Returns (status, header lines, body)."""
    with socket.create_connection(("127.0.0.1", port), timeout=5) as client:
        extra = "".join(f"{name}: {value}\r\n" for name, value in headers)
        head = (f"{method} {path} HTTP/1.1\r\nHost: x\r\nConnection: close\r\n{extra}"
                f"Content-Length: {len(body)}\r\n\r\n")
        client.sendall(head.encode() + body)
        data = b""
        while True:
            chunk = client.recv(65536)
            if not chunk:
                break
            data += chunk
    head, _, rest = data.partition(b"\r\n\r\n")
    lines = head.decode().split("\r\n")
    return int(lines[0].split(" ")[1]), lines[1:], rest


def workers_of(parent):
    """Live child pids of parent, from procfs (Linux)."""
    path = Path(f"/proc/{parent.pid}/task/{parent.pid}/children")
    text = path.read_text().split()
    return {int(pid) for pid in text}


def start(executable, workers):
    # The worker count goes through GOOSE_WEB_WORKERS, so the environment path is exercised end to end.
    port = free_port()
    env = dict(os.environ, GOOSE_WEB_WORKERS=str(workers))
    process = subprocess.Popen([str(executable), str(port)], stdout=subprocess.PIPE, text=True, env=env)
    deadline = time.monotonic() + 5
    while True:
        assert process.poll() is None, "workers fixture exited during startup"
        try:
            # A bare connection: it is accepted but completes no request, so the stats stay exact.
            socket.create_connection(("127.0.0.1", port), timeout=1).close()
            break
        except ConnectionRefusedError:
            pass
        assert time.monotonic() < deadline, "workers fixture did not start"
        time.sleep(0.02)
    time.sleep(0.05)
    return process, port


def wait_for(predicate, seconds):
    deadline = time.monotonic() + seconds
    while not predicate():
        if time.monotonic() > deadline:
            return False
        time.sleep(0.02)
    return True


def stop(process):
    """SIGTERM the parent and return (exit code, STATS fields)."""
    process.send_signal(signal.SIGTERM)
    out, _ = process.communicate(timeout=15)
    line = next((row for row in out.splitlines() if row.startswith("STATS ")), None)
    stats = list(map(int, line.split()[1:])) if line else None
    return process.returncode, stats


def test_concurrent_across_processes(executable):
    process, port = start(executable, 4)
    try:
        assert wait_for(lambda: len(workers_of(process)) == 4, 3), workers_of(process)
        children = workers_of(process)
        with ThreadPoolExecutor(max_workers=16) as pool:
            results = list(pool.map(lambda _: request(port, "/pid"), range(200)))
        assert all(status == 200 for status, _ in results), [status for status, _ in results if status != 200][:5]
        served = {int(body) for _, body in results}
        assert process.pid not in served, "the parent must not serve requests"
        assert served <= children, (served, children)
        assert len(served) >= 2, f"expected several worker processes to serve, saw {served}"
        print(f"  200 concurrent requests served by {len(served)} of 4 worker processes")
    finally:
        code, _ = stop(process)
        assert code == 0, code


def test_crash_is_replaced(executable):
    process, port = start(executable, 4)
    try:
        assert wait_for(lambda: len(workers_of(process)) == 4, 3)
        before = workers_of(process)
        try:
            request(port, "/crash")  # the worker that takes this request aborts
        except (ConnectionResetError, ConnectionAbortedError):
            pass
        # The crashed worker is gone and a replacement appears; the service keeps answering throughout.
        assert wait_for(lambda: len(workers_of(process)) == 4 and workers_of(process) != before, 5), workers_of(process)
        replacement = workers_of(process) - before
        assert replacement, "no replacement worker was started"
        for _ in range(50):
            status, body = request(port, "/health")
            assert status == 200 and body == b"ok", (status, body)
        # Accept order can favour the older workers, so requests go out concurrently in rounds until the
        # replacement answers, for up to five seconds.
        served = set()
        deadline = time.monotonic() + 5
        with ThreadPoolExecutor(max_workers=32) as pool:
            while not (served & replacement) and time.monotonic() < deadline:
                results = list(pool.map(lambda _: request(port, "/pid"), range(200)))
                assert all(status == 200 for status, _ in results)
                served |= {int(body) for _, body in results}
        assert served & replacement, "the replacement worker never served a request"
        print(f"  a crashed worker was replaced by pid {sorted(replacement)}; service continued")
    finally:
        code, _ = stop(process)
        assert code == 0, code


def test_shutdown_and_aggregated_stats(executable):
    process, port = start(executable, 4)
    children = workers_of(process)
    assert len(children) == 4
    for _ in range(100):
        status, _ = request(port, "/health")
        assert status == 200
    code, stats = stop(process)
    assert code == 0, code
    # accepted, completed, rejected, forced_closes, active, bytes_written. The readiness probe is
    # accepted but completes no request. Completed counts the 100 answered requests, summed over workers.
    assert stats is not None, "no STATS line from the parent"
    accepted, completed, rejected, forced, active, _ = stats
    assert completed == 100 and rejected == 0 and forced == 0 and active == 0, stats
    assert accepted >= 100, stats
    for pid in children:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            continue
        raise AssertionError(f"worker {pid} is still alive after the parent exited")
    print(f"  SIGTERM drained 4 workers: aggregated stats {stats}")


def test_zero_means_one_per_cpu(executable):
    process, port = start(executable, 0)
    try:
        expected = os.cpu_count()
        assert wait_for(lambda: len(workers_of(process)) == expected, 5), (expected, workers_of(process))
        print(f"  workers=0 started one worker per CPU ({expected})")
    finally:
        code, _ = stop(process)
        assert code == 0, code


def test_rate_limit_is_global(executable):
    """/limited allows 20 requests a minute. Sixty concurrent requests land on several workers; exactly 20 may pass."""
    process, port = start(executable, 4)
    try:
        assert wait_for(lambda: len(workers_of(process)) == 4, 3)
        with ThreadPoolExecutor(max_workers=12) as pool:
            statuses = list(pool.map(lambda _: send(port, "GET", "/limited")[0], range(60)))
        passed, refused = statuses.count(200), statuses.count(429)
        assert passed == 20 and refused == 40, statuses
        served = {int(send(port, "GET", "/pid")[2]) for _ in range(40)}
        assert len(served) >= 2, f"expected several workers, saw {served}"
        print(f"  rate limit held across workers: {passed} passed, {refused} refused, workers {len(served)}")
    finally:
        code, _ = stop(process)
        assert code == 0, code


def test_sessions_across_workers(executable):
    """A server-side session written by one worker is read by others; a forged cookie reads nothing."""
    process, port = start(executable, 4)
    try:
        assert wait_for(lambda: len(workers_of(process)) == 4, 3)
        status, headers, _ = send(port, "GET", "/session/set/alice")
        assert status == 200
        set_cookie = next((line for line in headers if line.lower().startswith("set-cookie: gw_session=")), None)
        assert set_cookie, headers
        cookie = set_cookie.split("=", 1)[1].split(";", 1)[0]
        assert len(cookie) == 87 and cookie[43] == ".", cookie  # id, dot, tag: the data is not in the cookie
        pids = set()
        for _ in range(40):
            status, _, body = send(port, "GET", "/session/get", headers=[("Cookie", f"gw_session={cookie}")])
            assert status == 200 and body.startswith(b"alice "), body
            pids.add(int(body.split()[1]))
        assert len(pids) >= 2, f"expected several workers to read the session, saw {pids}"
        forged = cookie[:-1] + ("B" if cookie[-1] == "A" else "A")
        status, _, body = send(port, "GET", "/session/get", headers=[("Cookie", f"gw_session={forged}")])
        assert status == 200 and body.startswith(b" "), body
        print(f"  server-side session read by {len(pids)} workers; a forged cookie reads nothing")
    finally:
        code, _ = stop(process)
        assert code == 0, code


def read_matching(stream, buffer, pattern, seconds=5):
    """Reads from stream until pattern matches the accumulated bytes. Returns (match, buffer)."""
    deadline = time.monotonic() + seconds
    while True:
        found = re.search(pattern, buffer)
        if found:
            return found, buffer
        if time.monotonic() > deadline:
            raise AssertionError(f"timed out waiting for {pattern!r} in {buffer[-200:]!r}")
        try:
            chunk = stream.recv(65536)
        except socket.timeout:
            continue
        if not chunk:
            raise AssertionError(f"stream closed waiting for {pattern!r}")
        buffer += chunk


def test_events_across_workers(executable):
    """A stream held by one worker receives events published by requests that other workers serve."""
    process, port = start(executable, 4)
    stream = None
    try:
        assert wait_for(lambda: len(workers_of(process)) == 4, 3)
        stream = socket.create_connection(("127.0.0.1", port), timeout=1)
        stream.sendall(b"GET /stream/9 HTTP/1.1\r\nHost: x\r\n\r\n")
        # The worker that holds the stream announces its process id as the first event.
        hello, buffer = read_matching(stream, b"", rb"event: hello\ndata: (\d+)\n")
        holder = int(hello.group(1))
        publishers = set()
        sent = 0
        for i in range(40):
            status, _, body = send(port, "POST", f"/publish/9", f"m{i}".encode())
            assert status == 200, status
            publisher, subscribers = body.decode().split(":")
            assert subscribers == "1", body  # one stream on channel 9, in whichever worker holds it
            publishers.add(int(publisher))
            sent += 1
            if publishers - {holder}:
                break
        assert publishers - {holder}, f"every publish came from the stream's own worker {holder}: {publishers}"
        last = -1
        for i in range(sent):
            found, buffer = read_matching(stream, buffer, rb"event: msg\ndata: m%d\n" % i)
            assert found.start() > last, "events arrived out of order"
            last = found.start()
        print(f"  stream held by pid {holder} received {sent} events published by pids {sorted(publishers)}")
    finally:
        if stream is not None:
            stream.close()
        code, _ = stop(process)
        assert code == 0, code


def main():
    executable = Path(sys.argv[1]) if len(sys.argv) > 1 else BUILD / "workers"
    test_concurrent_across_processes(executable)
    test_crash_is_replaced(executable)
    test_shutdown_and_aggregated_stats(executable)
    test_zero_means_one_per_cpu(executable)
    test_rate_limit_is_global(executable)
    test_sessions_across_workers(executable)
    test_events_across_workers(executable)
    print("Worker process tests passed: concurrent clients across processes, crash replacement, "
          "SIGTERM drain, aggregated stats, one worker per CPU, a global rate limit, server-side sessions "
          "across workers, events across workers")


if __name__ == "__main__":
    main()
