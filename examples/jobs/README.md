# Background jobs

A prime counter that runs on worker threads. `POST /primes?limit=N` queues the job and answers
`202` with an id at once. The count is computed on a thread, so other requests keep being served
while it runs. The reactor hands the result back in the tick, and `GET /events` announces it.

## Run

From the repository root:

```sh
mkdir -p build
goose build examples/jobs/server.goose -o build/jobs
./build/jobs --port 8080
```

Try it:

```sh
curl -s -i -X POST 'http://127.0.0.1:8080/primes?limit=2000000'   # 202 {"id":1,"status":"queued"}
curl -s http://127.0.0.1:8080/jobs/1                              # queued, then done with the count
curl -N http://127.0.0.1:8080/events                              # in another terminal: "done" events
```

Ctrl+C stops the server. The workers finish the jobs already queued, are joined, and the process exits.

## Routes

| Request | Response |
| --- | --- |
| `POST /primes?limit=N` (2 to 2000000) | `202` `{"id":N,"status":"queued"}`; `422 bad_limit` outside the range; `400` for a malformed number; `503 queue_full` when 4 jobs are already in flight; `503 tracking_full` when 64 jobs are tracked |
| `GET /jobs/:id` | `200` `{"id","status":"queued"\|"done"\|"failed","count","largest"}`; `404 not_found` for an unknown or cleaned-up id |
| `GET /events` | server-sent events; a `done` event with the job JSON for each finished job |

`count` is the number of primes up to `limit` and `largest` the greatest of them.

## What it shows

- `web::job_pool(2, 4)` with two workers and at most four jobs in flight. `job_start` spawns the
  workers; `job_submit` returns the correlation id or 0 when the queue is full, which the handler
  turns into a 503.
- `count_primes` is pure Goose (a sieve). It runs on a worker thread, so it may not call the
  framework's C code (sockets, the clock, SQLite, crypto). `prime_worker` is the `thread_fn` that the
  framework runs for each slot.
- `web::job_drain` in the tick gives each finished job's reply to `finish`, which records the result by
  id and publishes it with `web::sse_publish`.
- A scheduler task (`web::every`, 30 seconds) drops finished jobs older than 60 seconds. `web::due`
  runs it from the tick, and `web::hint_wakeup` keeps the reactor waking on time.
- `SERVER_STOPPING` calls `web::job_stop`, which waits for the workers.

The bounds are in the Background jobs section of [docs/api.md](../../docs/api.md#background-jobs).
The integration test is `tests/integration/jobs.py`.
