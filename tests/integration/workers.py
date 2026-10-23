#!/usr/bin/env python3
"""Pre-forked workers: concurrent clients across processes, a crashed worker is replaced, SIGTERM drains all,
aggregated stats, and workers=0 means one worker per CPU. Usage: workers.py [path-to-the-workers-fixture]."""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import os
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
        results = [request(port, "/pid") for _ in range(200)]
        assert all(status == 200 for status, _ in results)
        served = {int(body) for _, body in results}
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


def main():
    executable = Path(sys.argv[1]) if len(sys.argv) > 1 else BUILD / "workers"
    test_concurrent_across_processes(executable)
    test_crash_is_replaced(executable)
    test_shutdown_and_aggregated_stats(executable)
    test_zero_means_one_per_cpu(executable)
    print("Worker process tests passed: concurrent clients across processes, crash replacement, "
          "SIGTERM drain, aggregated stats, one worker per CPU")


if __name__ == "__main__":
    main()
