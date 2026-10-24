#!/usr/bin/env python3
"""Pre-forked workers: concurrent clients across processes, a crashed worker is replaced, SIGTERM drains all,
aggregated stats, workers=0 means one worker per CPU, the restart budget stops the server, a worker that
outlives the shutdown grace is SIGKILLed, and the stats of a crashed worker are lost while the rest are summed.
Usage: workers.py [path-to-the-workers-fixture]."""
from collections import Counter
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


def start(executable, workers, budget=None):
    # The worker count goes through GOOSE_WEB_WORKERS, so the environment path is exercised end to end.
    port = free_port()
    env = dict(os.environ, GOOSE_WEB_WORKERS=str(workers))
    arguments = [str(executable), str(port)] + ([str(budget)] if budget is not None else [])
    process = subprocess.Popen(arguments, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env)
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


def test_restart_budget_stops_the_server(executable):
    # Budget 2: the first two crashes are restarted, the third exit spends the budget. The server then
    # drains the survivors, returns false and exits 1 with a message on stderr.
    process, port = start(executable, 2, budget=2)
    assert wait_for(lambda: len(workers_of(process)) == 2, 3)
    for _ in range(3):
        try:
            request(port, "/crash")  # each one kills the worker that accepts it
        except OSError:
            pass
    try:
        out, err = process.communicate(timeout=15)
    except subprocess.TimeoutExpired:
        process.kill()
        raise AssertionError("the server kept running after the restart budget was spent")
    assert process.returncode == 1, (process.returncode, err)
    assert "restart budget is spent" in err, err
    message = next(line for line in err.splitlines() if "restart budget" in line)
    print(f"  restart budget of 2 spent: exit {process.returncode}, stderr says: {message}")


def test_sigkill_after_shutdown_grace(executable):
    # The fixture's grace is 2000 ms. A worker held in a 30-second handler cannot drain, so the parent
    # SIGKILLs it 500 ms after the grace and exits. Without the kill, the stop would take 30 seconds.
    process, port = start(executable, 2)
    children = set()
    blocked = None
    try:
        assert wait_for(lambda: len(workers_of(process)) == 2, 3)
        children = workers_of(process)
        blocked = socket.create_connection(("127.0.0.1", port), timeout=5)
        blocked.sendall(b"GET /block HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
        time.sleep(0.3)  # the worker that took the request is now inside its handler
        began = time.monotonic()
        process.send_signal(signal.SIGTERM)
        out, err = process.communicate(timeout=20)
        elapsed = time.monotonic() - began
    finally:
        if blocked is not None:
            blocked.close()
        if process.poll() is None:
            process.kill()
    assert process.returncode == 0, (process.returncode, err)
    assert 1.9 <= elapsed <= 5.0, f"stop took {elapsed:.2f} s: expected the 2 s grace plus the 0.5 s kill margin"
    for pid in children:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            continue
        raise AssertionError(f"worker {pid} survived the SIGKILL")
    print(f"  blocked worker SIGKILLed; stop took {elapsed:.2f} s (grace 2.0 s + 0.5 s margin); no worker survived")


def test_crashed_worker_stats_are_lost(executable):
    # A worker that aborts never writes its record, so the requests it answered are missing from the
    # totals. Every other worker's record is summed: completed = answered requests minus the lost ones.
    process, port = start(executable, 4)
    code, stats = None, None
    try:
        assert wait_for(lambda: len(workers_of(process)) == 4, 3)
        before = workers_of(process)
        with ThreadPoolExecutor(max_workers=16) as pool:
            served = list(pool.map(lambda _: request(port, "/pid"), range(200)))
        assert all(status == 200 for status, _ in served), [status for status, _ in served if status != 200][:5]
        per_pid = Counter(int(body) for _, body in served)
        try:
            request(port, "/crash")
        except OSError:
            pass
        assert wait_for(lambda: len(workers_of(process)) == 4 and workers_of(process) != before, 5), workers_of(process)
        crashed = before - workers_of(process)
        assert len(crashed) == 1, crashed
        lost = sum(per_pid[pid] for pid in crashed)
        assert lost > 0, f"the crashed worker answered none of the 200 requests: {per_pid}"
        more = [request(port, "/health") for _ in range(50)]
        assert all(status == 200 for status, _ in more)
    finally:
        code, stats = stop(process)
    assert code == 0, code
    # accepted, completed, rejected, forced_closes, active, bytes_written
    assert stats is not None, "no STATS line from the parent"
    accepted, completed, rejected, forced, active, _ = stats
    assert completed == 250 - lost, (stats, lost)
    assert accepted >= completed and rejected == 0 and forced == 0 and active == 0, stats
    print(f"  crashed worker answered {lost} requests; its stats were lost; totals completed={completed} "
          f"= 250 answered - {lost} lost")


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
    test_restart_budget_stops_the_server(executable)
    test_sigkill_after_shutdown_grace(executable)
    test_crashed_worker_stats_are_lost(executable)
    test_zero_means_one_per_cpu(executable)
    print("Worker process tests passed: concurrent clients across processes, crash replacement, "
          "SIGTERM drain, aggregated stats, restart budget, SIGKILL after grace, lost stats of a crashed "
          "worker, one worker per CPU")


if __name__ == "__main__":
    main()
