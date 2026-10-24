#!/usr/bin/env python3
"""examples/jobs over real sockets: 202 then completion by poll and by SSE, queue-full 503, shutdown joins workers."""
import json
import signal
import socket
import subprocess
import sys
import time
from pathlib import Path


def free_port():
    with socket.socket() as reservation:
        reservation.bind(("127.0.0.1", 0))
        return reservation.getsockname()[1]


def exchange(port, method, target):
    with socket.create_connection(("127.0.0.1", port), timeout=3) as client:
        client.sendall(method + b" " + target + b" HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
        data = b""
        while True:
            chunk = client.recv(65536)
            if not chunk:
                break
            data += chunk
    head, body = data.split(b"\r\n\r\n", 1)
    status = int(head.split(b" ", 2)[1])
    return status, json.loads(body) if body and body[:1] in b"{[" else body


def wait_for_done(port, job_id, timeout=20):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        status, view = exchange(port, b"GET", b"/jobs/%d" % job_id)
        assert status == 200, (status, view)
        if view["status"] != "queued":
            return view
        time.sleep(0.02)
    raise AssertionError(f"job {job_id} did not finish")


def read_event(sock, event_name, job_id, timeout=20):
    """Reads chunked SSE until a `done` event for job_id arrives; returns its JSON data."""
    sock.settimeout(timeout)
    buf = b""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            chunk = sock.recv(65536)
        except socket.timeout:
            break
        assert chunk, "event stream closed"
        buf += chunk
        while b"\n\n" in buf:
            block, buf = buf.split(b"\n\n", 1)
            for line in block.split(b"\n"):
                # Chunk-size lines are hex digits; the payload lines carry the event fields.
                if line.startswith(b"data: "):
                    data = json.loads(line[6:])
                    if data["id"] == job_id and event_name == "done":
                        return data
    raise AssertionError(f"no done event for job {job_id}")


def start(executable, port):
    process = subprocess.Popen([str(executable), "--port", str(port)], stdout=subprocess.DEVNULL,
                               stderr=subprocess.PIPE)
    deadline = time.monotonic() + 3
    while True:
        assert process.poll() is None, process.stderr.read().decode()
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.1):
                return process
        except ConnectionRefusedError:
            if time.monotonic() > deadline:
                raise
            time.sleep(0.02)


def test_jobs(executable):
    port = free_port()
    process = start(executable, port)
    try:
        status, body = exchange(port, b"POST", b"/primes?limit=1")
        assert status == 422 and body["error"]["code"] == "bad_limit", (status, body)
        status, body = exchange(port, b"POST", b"/primes?limit=abc")
        assert status == 400, (status, body)

        # 202 with an id, then completion by poll: pi(100000) = 9592, largest prime 99991.
        status, accepted = exchange(port, b"POST", b"/primes?limit=100000")
        assert status == 202 and accepted["status"] == "queued", (status, accepted)
        job_id = accepted["id"]
        view = wait_for_done(port, job_id)
        assert view == {"id": job_id, "status": "done", "count": 9592, "largest": 99991}, view

        status, body = exchange(port, b"GET", b"/jobs/%d" % (job_id + 1000))
        assert status == 404 and body["error"]["code"] == "not_found", (status, body)

        # Completion by SSE: subscribe first, then submit.
        with socket.create_connection(("127.0.0.1", port), timeout=3) as stream:
            stream.sendall(b"GET /events HTTP/1.1\r\nHost: x\r\n\r\n")
            head = b""
            while b"\r\n\r\n" not in head:
                head += stream.recv(4096)
            assert head.startswith(b"HTTP/1.1 200"), head
            status, accepted = exchange(port, b"POST", b"/primes?limit=50000")
            assert status == 202, status
            event = read_event(stream, "done", accepted["id"])
            assert event == {"id": accepted["id"], "status": "done", "count": 5133, "largest": 49999}, event

        # Queue full: the queue holds QUEUE_LIMIT (4) jobs in flight, so later requests get 503 until a drain.
        codes = []
        for _ in range(8):
            status, body = exchange(port, b"POST", b"/primes?limit=2000000")
            codes.append(status)
            if status == 503:
                assert body["error"]["code"] == "queue_full", body
        assert codes[:4] == [202, 202, 202, 202] and 503 in codes[4:], codes
        assert process.poll() is None

        # Shutdown with work in flight: the workers finish, are joined, and the process exits cleanly.
        process.send_signal(signal.SIGINT)
        process.wait(timeout=30)
        assert process.returncode == 0, process.returncode
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
    print("Jobs example tests passed: 202 and poll, SSE completion, 422 and 503 refusals, shutdown joins workers")


if __name__ == "__main__":
    executable = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[2] / "build/jobs_example"
    test_jobs(executable)
