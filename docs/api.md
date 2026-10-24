# API contracts

Public names such as `web::HTTP_OK`, `web::METHOD_GET`, and `web::CONTENT_TYPE_JSON`
are available through the package import. See the [constants reference](constants.md)
for fixed limits, configurable defaults, headers, and lifecycle identifiers.

## HTTP and headers

`Request` contains read-only `method`, `target`, `body`, and `raw_headers` views.
`request_header(request, name)` looks up the first case-insensitive header and returns
an empty view when missing. Empty and absent values are not distinguished.

`response()` returns status 200, text/plain UTF-8, an empty body, and no extra headers.
`set_header(response, name, value)` replaces case-insensitively or inserts; false leaves
state unchanged. Capacity is 16 headers, names 64 bytes, values 256 bytes. Invalid names,
controls, framing headers, and content-type overrides are rejected; use `content_type`
for that field. Serialization also validates direct struct mutations and rejects duplicates.
The body is a growable buffer, read with `body_of(response)` (a `const u8[:]` view) and `body_len(response)`.
Writes are `set_body(response, bytes) -> bool` (replaces the body) and `append_body(response, bytes) -> bool`
(extends it). Each returns false, leaving the response unchanged, when the write would exceed
`response.max_body`. The runtime sets `max_body` from `config.max_response_bytes` (default 1 MiB, ceiling
`MAX_RESPONSE_BODY_BYTES` = 16 MiB); an over-limit body becomes a complete 500 `response_too_large` JSON
error. Error envelopes may use `MAX_ERROR_BODY_BYTES` (64 KiB) beyond `max_body`, so a refused write can
still be replaced by its 500. `drop_body(response)` discards the body. Writes only append during a request
(the buffer never shrinks while a handler may hold views); the runtime clears it after the response is
serialized, and keeps its capacity for the next request, so memory tracks the largest response served
(bounded by the ceiling). `max_body` counts every byte the buffer holds, including bodies that were replaced,
so the bound holds however many writes a handler makes.

`append_header(response, name, value)` is `set_header` except for `Set-Cookie`, which may repeat:
each call adds one line (RFC 6265). Serialization allows repeated `Set-Cookie` and still rejects
any other repeated name, so `set_header` on `Set-Cookie` replaces the earlier line.

HTTP/1.0 and HTTP/1.1 origin-form requests use Content-Length bodies. Connections persist
(see the HTTP profile below); `Connection` is read as a case-insensitive token list.
Targets follow strict ASCII URI syntax with validated percent escapes; raw Unicode
and fragments are rejected. Host values must match the supported reg-name/bracketed
IPv6 profile, with optional numeric port. Only SP/HTAB are trimmed around field values.
Duplicate Host/Content-Length, invalid header names/control bytes, and ambiguous framing
return 400. Unsupported transfer encoding returns 501; Expect returns 417. HEAD sends
no body but retains the selected representation's length. Parser errors remain plain
text and close the connection; application errors use the JSON helper below. These are bounded experimental protocol rules, not a claim
of complete HTTP conformance.

## Routes and query values

```goose
var routes = web::router();
assert(web::add_route(routes, web::METHOD_GET, "/users/:id", 1));
let selected = web::match_route(routes, request.method, request.target);
// selected.status: 200, 404, or 405
// selected.handler_id selects your named handler; selected.allow supplies Allow.
let id = web::path_param(selected, "id");
```

The table owns 64 descriptors, methods up to 16 bytes, patterns up to 512 bytes, and
up to 16 named parameters. Failed registration leaves the table unchanged. Equivalent
same-method patterns are rejected. Registration also reserves a 256-byte Allow budget.
Static segments win before method selection; a wrong method on `/users/new` cannot
fall through to `/users/:id`. Explicit HEAD wins; otherwise GET handles HEAD.
Path case, trailing slashes, repeated slashes, and encoded bytes are exact; path
parameters consume one nonempty segment and are not percent-decoded.

`target_path(target)` and `target_query(target)` split on the first `?`.
`query_value(target, key)` returns owned `value` and `status`: 0 missing, 200 present
(including empty), 400 invalid escape, 413 decoded field over 1024 bytes. It decodes
percent escapes and `+` as space, preserves binary bytes, returns the first duplicate,
and validates all query fields even after finding the requested key. Callers must
check the status before using the value. No Unicode normalization is applied.

## Middleware and application errors

`valid_utf8(text)` checks that bytes form valid UTF-8, rejecting truncated, overlong,
surrogate, and out-of-range encodings. It does not reject control characters;
the consuming format or application applies that policy. The JSON codec checks UTF-8
before it parses a request body.

`pipeline(request, response, before, handler, after)` calls before first. Its boolean
result controls whether handler runs. After always runs when callbacks return normally,
including on rejection. Nest pipelines through a named handler for additional layers;
after-callbacks unwind from inner to outer. Do not use nonlocal returns to exit the
entire caller from a callback when relying on later callbacks.

`application_error(response, status, code, message)` emits:

```json
{"error":{"code":"not_found","message":"Route not found"}}
```

It returns true if the full error fits. Invalid status outside 400..599, malformed
UTF-8, or escaped data over the body limit produces a complete 500 `internal_error`
response and returns false. Existing headers survive. Inputs may borrow the response's
old fields; encoding completes before those fields change. Controls, quotes, and
backslashes are escaped, and valid multibyte UTF-8 is preserved.

## Events

`event_bus<T>()`, `subscribe(bus, topic, once=false)`, `unsubscribe(bus, id)`,
`dispatch(bus, topic, args)`, and `drain(bus, callback)` form the native event API.
The callback receives subscription ID and `Event<T> { topic, args }`.

- Arguments are owned fixed-size values; use structs for multiple arguments.
- 64 active listeners; subscribe returns 0 when full. IDs are not reused.
- 256 FIFO queued events; dispatch returns false when full.
- Listeners run in subscription order; unsubscribe takes effect immediately.
- One-shot listeners are removed before invocation. New listeners start with the next event.
- Drain processes only its initial batch; recursive drain returns 0. Do not replace the
  bus or exit the enclosing function nonlocally during drain.
- The bus belongs to its reactor thread. No cross-thread shared mutable state.

The example retains the requested 503 response on queue overflow. Applications must
choose this policy before side effects: returning 503 cannot undo completed work.

## Runtime configuration and lifecycle

`server_config()` provides these defaults:

| Field | Default | Valid range / meaning |
| --- | --- | --- |
| port | 8080 | 1..65535 |
| public_bind | false | loopback; true explicitly binds IPv4 wildcard |
| max_clients | 64 | 1..64 |
| max_request_bytes | 8192 | 1..8192, includes headers and body; a connection's input starts at 1 KiB and doubles up to this limit |
| max_response_bytes | 1048576 | 1..16777216, response body limit; larger bodies become a 500 |
| max_pool_bytes | 8388608 | `max_response_bytes` + 8192 .. 67108864, bytes of serialized responses in flight; a response that does not fit gets a 503 and the connection closes |
| read_timeout_ms | 5000 | 1..86400000, time to receive each request once its first byte arrives |
| write_timeout_ms | 5000 | 1..86400000, total write phase per response |
| idle_timeout_ms | 5000 | 1..86400000, wait for the next request's first byte on a persistent connection |
| poll_timeout_ms | 10 | 1..1000, capped by nearest active deadline |
| shutdown_grace_ms | 5000 | 0..86400000 |
| max_requests | 0 | nonnegative; 0 unlimited; server-wide completed responses before shutdown |
| max_requests_per_connection | 100 | 0..1000000; 0 unlimited; the last allowed response says `Connection: close` |
| keep_alive | true | false answers every request with `Connection: close` |
| handle_signals | false | opt-in process-wide SIGINT/SIGTERM ownership |
| max_sse_clients | 32 | 0..64; open event streams; the effective limit is `min(max_sse_clients, max_clients)`, and 0 disables streams |
| sse_heartbeat_ms | 15000 | 1..86400000, interval of the `: ping` comment on each stream |
| sse_max_queued_bytes | 262144 | 256..4194304, unsent bytes one stream may hold before it is dropped |
| workers | 1 | 0..256; 1 is the single-process reactor; 0 is one worker process per CPU; more than 1 pre-forks that many workers (see [Worker processes](#worker-processes)) |
| worker_restart_budget | 30 | 0..30; unexpected worker exits tolerated within 60 seconds before the server stops (see [Worker processes](#worker-processes)) |
| shared_store_bytes | 1048576 | 0 or 262144..268435456; the [shared store](#shared-store) that workers and streams use across processes; 0 turns it off |

Memory is bounded by these limits and is charged on demand. Each of the `max_clients` slots costs a
small record. A connection holds an input block only while it has request bytes to parse (1 KiB, doubling
to `max_request_bytes`), so idle keep-alive connections hold none. Serialized responses are charged to
`max_pool_bytes`. The SSE outbox costs nothing until the first `sse_publish`, then at most 256 KiB.
`examples/hello` starts at about 3.2 MB resident. Blocks and chunks are reused, not returned to the OS.
The reactor uses epoll on Linux and poll elsewhere; the configuration and stats are the same on both.

`validate_server_config(config)` rejects invalid combinations before opening a socket.
`serve_config(config, control, handler, tick, lifecycle)` returns false on invalid
configuration, bind/signal setup failure, fork failure, or fatal poll failure. Handler receives
request/response, tick receives no arguments, and lifecycle receives stage/stats.
All callbacks are synchronous. Tick can capture `control` and call `request_shutdown(control)`.
With `workers` other than 1, the same call pre-forks worker processes; see below.

Lifecycle stages are `SERVER_STARTED`, `SERVER_STOPPING`, and `SERVER_STOPPED`.
Shutdown closes the listener and drains already accepted clients until the grace
period expires. Idle persistent connections close at once; a request in flight finishes
with `Connection: close` and then the socket closes, and pipelined requests not yet
started are not run. `max_requests` triggers this drain; accepted work may take completed
responses past the threshold. `shutdown_requested` remains latched: clear it, or use
a fresh control, before restarting. Stats reset on a successful new run.

`control.stats` reports accepted (including capacity rejections), active, completed
(fully transmitted responses, including HTTP errors), rejected (capacity), timeouts,
forced_closes (grace/fatal cleanup), bytes_read, bytes_written, and reused. Protocol errors
are not capacity rejections. Idle timeout closes the socket without a response.
`reused` counts responses served on a connection that had already completed one.
Event streams add `sse_active` (open streams), `sse_sent` (events queued to streams) and
`sse_dropped` (streams closed because they fell behind or the pool ran out).

Signals are optional for embedding; the basic example enables them. Only one
signal-owning server may run in the process, and previous handlers are restored on
normal exit. Multithreaded embedders should manage signals externally. The legacy
`serve(port, max_requests, handler, tick)` wrapper keeps loopback defaults.

## Worker processes

`workers` pre-forks several copies of the server on one listening socket, so requests
are served on all CPU cores. It is the process model of nginx and gunicorn: no Goose
threads are involved, and each worker is a separate process with its own memory.

| `workers` | Behavior |
| --- | --- |
| `1` (default) | The single-process reactor, unchanged. |
| `0` | One worker per online CPU (`sysconf(_SC_NPROCESSORS_ONLN)`). |
| `2`..`256` | That many workers. |

```goose
var config = web::server_config();
config.port = 8080;
config.workers = 4;
let started = web::run(config) { c => app(c) };
```

From the command line, `--workers N` (or `--workers=N`) and `GOOSE_WEB_WORKERS=N` set the
count; see [Command-line and environment configuration](#command-line-and-environment-configuration).
Start from `server_config()`, which sets `workers = 1`. A zeroed `default<web::ServerConfig>()` has
`workers = 0`, which means one worker per CPU.

**Process model.**

- The parent process opens the listener (nonblocking, `SO_REUSEADDR`), installs SIGINT and
  SIGTERM handling, and forks the workers. It never serves requests. A worker inherits the
  listener and runs the ordinary reactor on it with `workers = 1`. Each worker accepts from
  the shared socket; the kernel decides which worker takes each new connection, and a
  keep-alive connection stays with the worker that accepted it.
- With `workers` other than 1 the parent always owns SIGINT and SIGTERM, whatever
  `handle_signals` says, because it is the only process that can stop the others.
  Workers always take the signals themselves.
- `request_shutdown(control)` and `SIGINT`/`SIGTERM` sent to the parent stop the server.
  Ctrl+C reaches the whole process group, so every worker also starts its own drain.

**Callbacks.** `handler` (and every route) runs in the workers. `tick` runs in the parent
about every 20 ms, and in each worker at the reactor's cadence. `lifecycle` is called by the parent
with `SERVER_STARTED` (after the workers are forked), `SERVER_STOPPING` (when shutdown
begins) and `SERVER_STOPPED` (with the aggregated stats). Workers run `ignore_lifecycle`.

**State is per worker.** A fork copies the program's memory, and nothing is shared afterwards.
Anything a request can change is private to the worker that handled it:

- Global variables, route tables, the request counter behind `request_id` and any in-memory store
  differ from worker to worker. Entries, counters, `rate_limit` counts, server-side sessions and events
  are shared through the [shared store](#shared-store) while it is on (the default). Signed-cookie
  sessions live in the cookie and need no sharing. The basic Todo
  example keeps its list in memory and rewrites its JSON file from that copy, so it must run with
  `workers = 1`: several workers would overwrite each other's data. Keep such state in a database
  (`examples/sqlite-todos`) or run one worker.
- `web::sse_publish` reaches the streams of every worker while the shared store is on (the default):
  the message goes through the store's event ring and each worker copies it to its own streams. With
  the store off, it reaches only the streams open in the calling process.
- `max_requests` counts per worker: each worker stops after that many responses and the parent
  replaces it. The parent does not apply the limit to the server as a whole.
- `max_clients`, `max_sse_clients` and `max_pool_bytes` are per worker, so the process total is
  a multiple of them.

**SQLite and other open resources.** SQLite forbids carrying an open connection across
`fork`. The rule for this framework is that the parent opens nothing a worker will use. The
`examples/sqlite-todos` program opens and closes its database file once in `main` (to validate
the path and create the table), then each process opens its own connection on the first request
(`ensure_database`). Any application that opens a file, socket or database before `run` must
close it first or open it lazily in the handler. A worker that inherits an open handle and uses
it corrupts the database.

**Stats.** When a worker stops, it sends its `ServerStats` to the parent as one fixed-size frame
on a pipe, `STATS_RECORD_BYTES` (272) long and written whole. The frame is a magic word
(`STATS_RECORD_MAGIC`, the ASCII `GWSTATS1`), the field count, then each `i64` field as eight
little-endian bytes in declaration order, zero-padded to `STATS_FIELD_CAPACITY` (32) fields. The
encoder and decoder walk `fields<ServerStats>` with `const for`, and the parent sums with the same
walk, so a field added to `ServerStats` is carried and summed without other edits. The parent drops a
frame whose length, magic or field count does not match its own build, and the pipe stays aligned on
the next frame. The parent sums the frames into `control.stats`, so `SERVER_STOPPED` receives the
totals of every worker that stopped cleanly. `active` and `sse_active` are zero at that point. The
parent's stats are zero until the first worker stops. A worker that crashes or is killed after the
grace period sends no frame, so its counts are lost, including the `accepted` count; the other
workers' counts are still summed, so `completed` is the total answered by the workers that stopped
cleanly and leaves out what a crashed worker answered.

**Supervision.** A worker that exits without being asked (a crash, a signal other than the
parent's shutdown, or its own `max_requests` or `request_shutdown` from its tick) is restarted.
Restarts back off from 50 ms, doubling to 2 s; a worker that lived for ten seconds resets its
backoff. Restarts are budgeted by `worker_restart_budget` (default 30, the largest accepted value):
when more restarts than that happen within 60 seconds, the parent writes
`goose-web: workers kept exiting and the restart budget is spent; the server stops` to stderr, stops
the other workers, and `serve_config` returns false. The application then decides its exit status;
the fixture in `tests/fixtures/workers.goose` exits 1. A budget of 0 stops the server at the first
unexpected exit. A crash loop is a fault to fix rather than to mask. A failed `fork` stops the
server the same way.

**Shutdown.** The parent closes the listener and sends SIGTERM to every worker. A worker drains
as in the single-process case: idle connections close at once, in-flight requests finish with
`Connection: close`, and the listener is already closed. The parent waits for every worker to
exit. Workers still running `shutdown_grace_ms + 500 ms` after the stop began are sent SIGKILL and
reaped, so the parent exits within that bound even when a handler blocks the reactor. The requests
such a worker was serving are cut off, and its stats are lost.

**Linux and portability.** Workers are created with `fork` and, on Linux, `PR_SET_PDEATHSIG`
so that a worker whose parent dies receives SIGTERM and drains. The mechanism is POSIX; the
accept sharing relies on a nonblocking shared listener, so every worker wakes when a connection
arrives and the losers see `EAGAIN` (a thundering herd of a few wakeups per connection, which
is cheap at these sizes). `EPOLLEXCLUSIVE` would remove it once an epoll backend exists.

Use `bench/load.c` to measure a server under keep-alive load:
`cc -O2 bench/load.c -o build/load` then `build/load -c 64 -d 5 -P 8080 -p /health`.

## Server-sent events

A handler starts a stream with `c.sse(channel)`. The reactor then sends the head and keeps the
connection open. Application code publishes events on a channel from a tick, an event drain or a
handler, and each event reaches every stream subscribed to that channel. Design and bounds are in
[docs/design/app-api.md](design/app-api.md#v05-design-server-sent-events).

```goose
var control = default<web::ServerControl>();

fn tick() {
    // One event to every stream on channel 1; returns how many streams it was accepted for.
    web::sse_publish(control, 1, "time", "12:00:00");
}

fn app(c: web::Ctx&) {
    c.routes() {
        c.get("/events") { c.sse(1); };    // headers set with c.set go into the stream head
    };
}

fn main() {
    var config = web::server_config();
    config.handle_signals = true;
    let started = web::run_with(config, control, app, tick, web::ignore_lifecycle);
    if !started { abort("server failed"); }
}
```

- `c.sse(channel: i32) -> bool` returns false, changing nothing, when a response was already
  written. Return from the route straight after it. The stream head is `200`,
  `Content-Type: text/event-stream`, `Cache-Control: no-cache` and `Transfer-Encoding: chunked`.
- `web::sse_publish(control: ServerControl&, channel: i32, event: const u8[:], data: const u8[:]) -> i64`
  frames one message: an `event:` line when `event` is not empty, one `data:` line per line of `data`
  (CR, LF and CRLF all end a line), and a blank line. `-1` means refused: the event name contains CR or
  LF or is longer than 128 bytes, the data exceeds 65536 bytes, the framed message exceeds
  `sse_max_queued_bytes`, or the outbox is full. `0` means nothing could receive it: the server is not
  running, is stopping, or no stream subscribes to the channel. Otherwise the result is the number of
  streams on the channel when the message was accepted. With the shared store on, that count covers
  the streams of every worker, and the message is accepted when it fits the event ring.
- Publishing is staged in a bounded outbox (256 KiB, 64 messages) and copied to each stream at the
  start of the next loop iteration, so events reach the sockets in publish order. With the shared store
  on, the framed message goes to the store's event ring instead (a quarter of the store, the oldest
  messages overwritten first), and every worker copies new messages to its streams in the same order.
  See [Shared store](#shared-store).
- Heartbeats: every `sse_heartbeat_ms` each stream gets a `: ping` comment. Streams have no read or idle
  timeout. Bytes the client sends on a stream are discarded.
- A stream whose unsent bytes would pass `sse_max_queued_bytes`, or when the pool has no chunks left,
  is closed and counted in `sse_dropped`. Other streams are unaffected.
- Limits: HTTP/1.1 GET only. HTTP/1.0 and HEAD requests asking for a stream get `400`. A stream
  refused because the server is stopping or `max_sse_clients` streams are open gets `503`. Streams do
  not count toward `max_requests`, and `keep_alive` does not apply to them.
- Shutdown: when stopping begins, each stream receives `event: close` and the terminating chunk
  `0\r\n\r\n`, then closes. Grace still applies, so a stream that never reads is force-closed when
  the grace period ends.

A complete example that sends the time every second, with a browser page using `EventSource`, is in
[examples/sse-clock](../examples/sse-clock/README.md).

## Scheduler

`web::scheduler()` is a bounded table of periodic and one-shot tasks that the tick runs on the reactor
thread. It starts no thread and never waits. Work that takes longer than a tick belongs in a
[background job](#background-jobs) instead.

```goose
var sched = web::scheduler();              // 64 tasks, fixed
var control = default<web::ServerControl>();

fn tick() {
    web::due(sched) { id => run_task(id) };   // each due task runs once; returns how many ran
    web::hint_wakeup(sched, control);         // optional: wake for the next due task
}

fn main() {
    assert(web::every(sched, 1, 30000));      // id 1 every 30 s (first run after 30 s)
    assert(web::after(sched, 2, 500));        // id 2 once, after 500 ms
    // ... web::run_with(settings, control, app, tick, lifecycle)
}
```

| Function | Meaning |
| --- | --- |
| `scheduler() -> Scheduler` | An empty table |
| `every(sched, id, interval_ms) -> bool` | Runs `id` every interval, first after one interval |
| `after(sched, id, delay_ms) -> bool` | Runs `id` once, after the delay (0 means at the next tick) |
| `cancel(sched, id) -> bool` | Removes `id`; false when it is not scheduled |
| `due(sched) { id => ... } -> i64` | Runs each due task once with its id; returns how many ran |
| `next_due_ns(sched) -> i64` | Monotonic time of the earliest due task, 0 when none |
| `hint_wakeup(sched, control)` | Sets `control.wake_at_ns` so the reactor wakes for the next task |
| `every_at`, `after_at`, `due_at` | The same with an explicit monotonic time in nanoseconds, for tests with a fake clock |

- Ids are chosen by the application (any `i64`). Scheduling an id that is already scheduled replaces its
  timing; there is never a second task with the same id.
- Durations are whole milliseconds: `every` needs 1 to 86400000, `after` 0 to 86400000.
- Times come from the monotonic clock (`clock_ns`), so wall-clock changes do not move tasks.
- **Catch-up:** a periodic task that is late runs once when the tick sees it due. Its next run is the
  first point of its phase after now. Missed intervals are skipped, never replayed. A one-shot task runs
  once and is removed.
- Within one `due` call, tasks run in table order, and only tasks scheduled before the call are
  considered. A task added or cancelled by a block takes effect in the next call; a task cancelled
  by an earlier block in the same call does not run.
- **Timing:** without a hint the reactor wakes at its `poll_timeout_ms` (10 ms by default) at most, so a
  task runs at most that late. `hint_wakeup` in the tick makes the reactor wake on time for the next
  task, and it is replaced on each call. A task scheduled from a handler is seen at the next tick, so it
  can wait up to one poll interval.
- Tasks run on the reactor, one after another, so each must return quickly. A task that waits, for
  a socket or a long computation, blocks every connection; send that work to a job instead.

## Background jobs

Work that is CPU-heavy or blocks for long runs on Goose threads, so the reactor keeps serving. A job
is submitted from a handler, runs on a worker thread, and its result returns to the reactor in the
tick. The implementation is `src/jobs/pool.goose`; the example is [examples/jobs](../examples/jobs/README.md).

### What may run in a thread

A worker is a `thread_fn`, compiled as a separate program with copies of the globals it uses. `goose_web.build`
declares `main_thread_only = true`, which the compiler checks per call path:

- Pure Goose runs in a worker. A `thread_fn` that calls framework Goose which does not reach the package's C
  (for example `web::validate_server_config`) compiles and runs (checked with a scratch program while building the pool).
- A `thread_fn` that reaches any package C function is a compile error:
  `process runs on the main thread only: web::clock_ns is reached from thread_fn c_worker`. That covers
  sockets and the transport, the clock, SQLite (`web::db`), crypto (`web::sha256`, HMAC, random bytes),
  files and the process shim. Such calls stay on the reactor thread.
- Jobs and results must be flat (no slices, no `u8[>..]` builders, no references). A `thread_fn`'s
  parameters have no defaults.
- Thread programs do not share state: the job body reads its arguments and returns a value.

Generic code works through function values: `web::job_worker<Job, Result>(slot, render)` runs the
application's `render` in the worker. A `thread_fn` cannot itself be generic or be named with type
arguments (`thread_spawn(gen<Job>)` is a parse error), so each job type gets its own `thread_fn`.

### The pool

```goose
struct PrimeJob { limit: i64 }
struct PrimeResult { count: i64, largest: i64 }

thread_fn prime_worker(slot: i64) {
    web::job_worker<PrimeJob, PrimeResult>(slot, count_primes);   // count_primes is pure Goose
}

var jobs: web::JobPool;

fn main() {
    jobs = web::job_pool(2, 4);                                  // 2 workers, 4 jobs in flight
    web::job_start<PrimeJob, PrimeResult>(jobs, prime_worker);
    // ...
}

fn post_primes(c: web::Ctx&, limit: i64) {                       // handler
    let id = web::job_submit(jobs, PrimeJob { limit: limit });  // 0 means refused
    guard id > 0 else { c.fail(web::HTTP_SERVICE_UNAVAILABLE, "queue_full", "retry later"); return; }
    c.status(web::HTTP_ACCEPTED).json(JobAccepted { id: id, status: "queued" });
}

fn tick() {                                                      // reactor thread
    web::job_drain<PrimeResult>(jobs, prime_worker) { r => finish(r) };
}

fn lifecycle(stage: i32, stats: web::ServerStats) {
    if stage == web::SERVER_STOPPING { web::job_stop<PrimeJob>(jobs); }
}
```

| Function | Meaning |
| --- | --- |
| `job_pool(workers, queue_limit) -> JobPool` | `workers` in 1 to 16, `queue_limit` at least 1 (asserted). Nothing starts yet |
| `job_start<J, R>(pool, worker)` | Starts the workers, each a contained `thread_fn` with a watcher, and sets the queue limits |
| `job_submit(pool, body) -> i64` | Queues a job and returns its correlation id (at least 1), or 0 when refused |
| `job_drain<R>(pool, worker) { r => ... } -> i64` | Calls the block for each DONE and LOST reply; returns how many. Call it from the tick |
| `job_stop<J>(pool) -> bool` | Sends stop messages after the queued jobs, joins every thread, and returns |
| `job_worker<J, R, F>(slot)` | The body of the worker `thread_fn`; `F` is the job function, passed as a trailing argument |
| `job_in_flight(pool)`, `job_restarts(pool)` | Jobs queued or running and not yet drained; worker restarts since start |

`JobReply<R>` carries `id` (the correlation id from `job_submit`), `slot`, `kind` and `value`. The block
sees `kind == JOB_DONE` with the result, or `kind == JOB_LOST` with a zero value when the worker
aborted during that job. `JOB_STARTED` replies are consumed by the drain and never reach the block.

**Bounds and failure:**

- At most `queue_limit` jobs are in flight: queued or running, until the tick drains their reply. A submit
  beyond that returns 0, so the handler answers 503 and nothing is queued. The queue holds only what is in
  flight, so memory is bounded by `queue_limit` times the job size.
- A job that aborts (`abort`, a failed check) ends only its worker, which is contained. The job is
  reported as `JOB_LOST`, the abort message is printed (`web: job worker N aborted: ...`), and the slot is
  started again on the next tick. `job_restarts` counts the restarts. Each slot has one watcher thread
  that waits for its worker and reports the abort through a queue. That is the only way the reactor
  learns of an abort without polling.
- Results are never dropped: a worker's replies fit in the reply queue because `queue_limit` bounds the
  jobs in flight. A result the app does not drain stays in flight, so it applies backpressure.

**Correlation:** `job_submit` returns the id; the handler records it with the request state (the example
keeps a bounded table of tracked jobs), and `finish` looks the id up when the reply arrives. A reply for an
unknown id is ignored by the application.

**Shutdown:** on `SERVER_STOPPING`, `job_stop` queues stop messages behind the queued jobs and joins
every worker and watcher. So queued jobs finish first, and a long job delays the shutdown, so bound job
work. Replies still queued stay there, and a `job_drain` after the stop announces them. Thread waits on a
worker that already aborted return at once.

**One pool per program at a time:** queues are per job type, so two pools with the same types would share
a job queue. `job_start` asserts that no other pool is running; `job_stop` releases the slot.
## Shared store

A fixed-size memory region that every worker process of one server reads and writes. The parent creates
it in `serve_config`, before it forks the workers, so a single-process server creates it too and the code
path is the same. It has three parts: key/value entries with optional expiry, counters, and the event ring
that carries `sse_publish` between workers. The size is `shared_store_bytes`: 1 MiB by default, 0 to turn
it off, and 256 KiB to 256 MiB otherwise. A quarter of the space after the header holds the event ring, a
fixed registry holds the open streams (2048), and the rest is the entry table, about 650 entries of up to
1 KiB each at the default size. The store is created when the server starts and is not persisted: a restart
starts it empty. It stays mapped after the server returns until the process exits or another server starts.

```goose
fn app(c: web::Ctx&) {
    c.routes() {
        c.get("/visits") {
            let total, ok = web::shared_incr("visits", 1, 0);
            if !ok { c.fail(web::HTTP_SERVICE_UNAVAILABLE, "store_full", "No room for the counter"); return; }
            c.text(str(total));
        };
    };
}
```

| Call | Meaning |
| --- | --- |
| `web::shared_set(key, value, ttl_ms = 0) -> bool` | Stores `value` under `key`, replacing an earlier value. `ttl_ms = 0` keeps it until it is deleted or replaced; otherwise it expires after `ttl_ms` milliseconds. Returns `false`, storing nothing, when refused or full. |
| `web::shared_get(key, out: u8[>..]&) -> bool` | Copies the live value into `out`, which is cleared first. Returns `false`, with `out` empty, when the key is absent, expired or the store is off. |
| `web::shared_delete(key) -> bool` | Removes a live entry. |
| `web::shared_incr(key, delta, ttl_ms) -> i64, bool` | Adds `delta` to a counter and returns the new value. A missing or expired counter starts at 0 and takes `ttl_ms`. An existing counter keeps its expiry, so `ttl_ms` opens a fixed window that later increments do not extend. |
| `web::shared_incr_window(key, delta, ttl_ms) -> i64, i64, bool` | As `shared_incr`, and also the milliseconds left before expiry (0 when it never expires). |
| `web::shared_enabled() -> bool` | Whether this server has a store. |

**Bounds.** Keys are 1 to 128 bytes and values are at most 1024 bytes. A key or value outside those
bounds is refused, never truncated. `ttl_ms` is at most 365 days. A counter is an 8-byte integer, so
`shared_incr` fails on a key that holds some other value, and on overflow.

**Full table.** A new key is refused when no slot is free. The store never evicts a live entry to make
room. Deleting an entry frees its slot, and so does expiry: an expired entry's slot goes to the next new
key that probes over it. Check the return value of `shared_set` when the table can fill up.

**Crash safety.** The table, the ring and the stream registry sit behind one process-shared robust mutex.
A worker that dies while holding it does not block the others: the next locker takes the mutex over
(`EOWNERDEAD`, then `pthread_mutex_consistent`) and drops any entry whose write was in progress, so an
interrupted entry is absent afterwards and its old value is not restored. A ring message becomes visible
only after it is complete, so no reader sees a partial event. Streams registered by a dead worker are
removed the next time another process counts or adds streams. The lock has no timeout, so a worker that
is stopped (SIGSTOP) while holding it stalls the others until it resumes. `tests/native/shared.c` kills
a child while it holds the lock and checks that the next locker recovers.

**Events.** With the store on, `sse_publish` appends the framed message to the ring, and each worker copies
the messages it has not yet seen to its own streams, in publish order, at the start of its next loop pass.
A worker starts reading at the current end of the ring, so it never replays older events. A worker that
falls more than a ring behind loses the messages that were overwritten; the store counts them in its `lost`
total, which native code and tests can read but the Goose API does not expose yet. The count that
`sse_publish` returns covers every worker's streams. A stream opened when the registry is full gets 503.

**What is shared.** With the store on (the default):

| State | Scope |
| --- | --- |
| `shared_*` entries and counters | every worker of one server |
| `rate_limit` counts | every worker; the per-process table takes over only when the store is off or full |
| Server-side sessions (`SessionConfig.store`) | every worker |
| `sse_publish` events and stream counts | every worker |

Still per worker: global variables, route tables, any cache you keep in memory, the `request_id` counter,
`max_requests`, and each worker's sockets, buffers and stream queues. Stats are still summed by the parent.

**Which store to use.**

- The shared store fits small, fast state that every worker on one host must agree on, and that may be
  lost on restart: counters, rate limits, short-lived sessions, one-time tokens, presence, cache entries
  and event fan-out to streams on that host. Its size is fixed, it has no queries, and it covers one host only.
- SQLite (`web::db`) fits data that must survive restarts and needs queries, indexes or transactions on one
  host. Open the connection in each worker after the fork, as `examples/sqlite-todos` does. SQLite serializes
  writers, so keep write transactions short.
- An external database (PostgreSQL or similar) fits data that several machines must share, durability and
  backups beyond one disk, replication, or data larger than memory. The shared store is per host: two
  instances, or two machines, each have their own.

If losing the state on restart is acceptable and one host is enough, use the shared store. If the data must
survive restarts, use SQLite. If several hosts must see one copy, use an external database.
## TCP servers and clients

`web::tcp_serve` runs a nonblocking TCP loop for custom protocols, next to the HTTP server. It reuses
the listener, accept, recv and send calls of the HTTP transport but has its own readiness instance
(`native/posix/net.c`), so it holds up to 1024 connections where the HTTP reactor holds 64. The code is
in `src/net/tcp.goose` (server and client), `src/net/framing.goose` (line and frame helpers) and
`src/constants/tcp.goose`; `web::TcpConfig`, `web::TcpControl`, `web::TcpEvent` and the functions below
are all in the `web` namespace.

```goose
import goose_web from "goose_web";   // or the path to this checkout
import std;
import os;

var control = default<web::TcpControl>();

fn tick() {}

fn on_event(net: web::TcpControl&, ev: web::TcpEvent) {
    match ev {
        Data d => { if !web::tcp_send(net, d.conn, d.bytes) { web::tcp_close(net, d.conn); } },
        _ => {},
    }
}

fn main() {
    var config = web::tcp_config();          // port 9000, loopback, 256 connections
    config.port = 7000;
    config.handle_signals = true;             // SIGINT and SIGTERM drain, then the loop returns
    let started = web::tcp_serve(config, control, on_event, tick);
    if !started { abort("tcp server failed to start"); }
}
```

`tcp_serve(config, control, handler, tick)` returns when the loop stops. It returns `false`, without
serving, when `config` is invalid or the listener cannot start. `handler` is a named function
`fn(net: web::TcpControl&, ev: web::TcpEvent)`; `tick` is a named function called once per loop pass. Both
run synchronously on the loop thread, so neither may block. As with `run_with`, function values are
compile-time: pass them by name.

### Configuration

| Field | Default | Range and meaning |
| --- | --- | --- |
| `port`, `public_bind` | 9000, loopback | `public_bind` listens on all IPv4 interfaces |
| `max_conns` | 256 | 1 to 1024 connection slots; the rest are refused at accept |
| `read_buffer_bytes` | 16384 | One receive buffer shared by all connections; at most 1 MiB |
| `max_write_queue_bytes` | 262144 | Unsent bytes per connection, at least 4096 and at most 16 MiB |
| `idle_timeout_ms` | 60000 | A connection with no read or progressing write for this long closes; 0 disables it. The timer keeps running while the handler has paused reads. |
| `connect_timeout_ms` | 5000 | Deadline for `tcp_connect` to complete |
| `shutdown_grace_ms` | 5000 | Time given to flush queues and to lingering peers after a stop |
| `poll_timeout_ms` | 10 | Longest wait per loop pass, 1 to 1000 |
| `handle_signals` | false | Opt in to SIGINT and SIGTERM as a graceful stop (one signal-enabled server per process) |

`tcp_config()` returns the defaults. Only one TCP loop runs at a time per process, as with the reactor.
There is no worker-process mode for TCP: a TCP loop runs in one process, so use one process per listener
or put a process manager in front. `workers` is not a `TcpConfig` field.

### Events

| Event | When | Fields |
| --- | --- | --- |
| `Open { conn }` | A connection was accepted, or a `tcp_connect` completed | `conn` is the connection id |
| `Data { conn, bytes }` | Input arrived | `bytes` is a view valid only during the event |
| `Writable { conn }` | A queue that reached high water drained below it | Resume producing output for `conn` |
| `Closed { conn, reason }` | The connection is gone | `reason` is one of the `TCP_CLOSE_*` constants |

For one connection the order is `Open`, zero or more `Data` and `Writable`, then `Closed`. A connection id
(`conn`) is the slot index plus the slot's generation times 1024, so an id held after its connection closed
never names a newer connection; the functions below return 0 or false for it. Per-connection
application state is kept in your own tables indexed by `web::tcp_slot_of(net, conn)`, which is stable for
the life of the connection. `tcp_tag` / `tcp_set_tag` hold one `i64` per connection, reset to 0 on open.

Close reasons: `TCP_CLOSE_PEER` (the peer closed), `TCP_CLOSE_ERROR` (socket error), `TCP_CLOSE_IDLE`,
`TCP_CLOSE_APP` (`tcp_close`), `TCP_CLOSE_SHUTDOWN`, `TCP_CLOSE_CONNECT_FAILED` and
`TCP_CLOSE_CONNECT_TIMEOUT`.

### Functions

| Function | Meaning |
| --- | --- |
| `tcp_send(net, conn, bytes) -> bool` | Queues bytes. False, taking nothing, when the connection is not open or the queue would exceed `max_write_queue_bytes`. The caller may then close it. |
| `tcp_broadcast(net, bytes) -> i64` | Queues bytes on every open connection with room; returns how many accepted them |
| `tcp_close(net, conn) -> bool` | Closes after the queue is sent (FIN, then the peer may still send until it closes or the grace ends) |
| `tcp_pause_reads(net, conn, paused) -> bool` | Stops or resumes reading from a connection. Proxies use it for backpressure. |
| `tcp_queued(net, conn) -> i64` | Unsent bytes on the connection |
| `tcp_high_water(net) -> i64` | Queue size at which reads pause and `Writable` is owed |
| `tcp_peer(net, conn) -> const u8[:]` | The peer's numeric address |
| `tcp_connect(net, host, port) -> i64` | Starts a nonblocking connect to a numeric IPv4 or IPv6 address. Returns the connection id, or 0 when the loop is not running, no slot is free, or the address is refused at once. |
| `tcp_slot_of(net, conn) -> i64` | Slot index for a live connection, or -1 |
| `tcp_conn_at(net, slot) -> i64` | Connection id in a slot, or 0 when free; walk `0 .. max_conns-1` to reach every connection |
| `tcp_request_shutdown(net)` | Stops the loop from inside a handler or from `tick` |
| `control.stats` | `TcpStats`: accepted (includes refused), active, connects, closed, rejected, timeouts, bytes_read, bytes_written, refused_sends |

Names are never resolved: `tcp_connect` takes a numeric address. A name needs `getaddrinfo`, which blocks
the loop. Resolve it in advance (or at startup in `main`) and pass the address.

### Backpressure

Each connection has a write queue of 4 KiB chunks drawn from one shared pool. `tcp_send` appends to it,
and the loop sends from its head as the socket accepts bytes. The queue never exceeds
`max_write_queue_bytes`. At half of that (the high-water mark) the loop stops reading from the connection,
so a peer that does not read stops sending too, and a `Writable` event tells the handler when the queue
drained below high water. Memory is bounded by `max_conns * (max_write_queue_bytes + 8 KiB)` plus the
receive buffer. `tests/integration/tcp.py` checks this: a client that sends 16 MiB and does not read
makes the server read only the kernel buffers plus the queue.

Application flow control works the same way: a proxy calls `tcp_pause_reads` on its client while the
upstream queue is above `tcp_high_water`, and resumes on the upstream's `Writable`.

### Framing

`web::TcpFrame` is a per-connection accumulation buffer (`TCP_FRAME_CAPACITY`, 8 KiB, inline). Declare
one per slot in your own table: `var frames: web::TcpFrame[64];` and index it with `tcp_slot_of`.

- `tcp_feed_lines(frame, data, max_line) { line => ... } -> bool` splits data on `\n`, drops a trailing
  `\r`, and calls the block once per complete line with a view of it. A line longer than `max_line` fails
  the feed (`false`, buffer cleared): send an error and close.
- `tcp_feed_frames(frame, data, header, max_frame) { payload => ... } -> bool` reads big-endian
  `header`-byte lengths (2 or 4) and delivers each payload. A length above `max_frame` fails the feed
  as soon as the header is complete. `header + max_frame` must fit `TCP_FRAME_CAPACITY`.
- `tcp_encode_frame(out, payload, header)` appends one frame to a builder for `tcp_send`.

Feeds keep partial lines and frames across calls, so a message split over any number of Data events is
delivered whole.

### Client connections

`tcp_connect` shares the loop: the connection's `Open` or `Closed` arrives as an event like any accepted
connection, so one loop can serve clients and upstreams together. A `Closed` with
`TCP_CLOSE_CONNECT_FAILED` (refused, unreachable) or `TCP_CLOSE_CONNECT_TIMEOUT` follows a failed attempt
that started; an immediate failure returns 0 instead. Tag the upstream connection with `tcp_set_tag` before
its `Open` if the handler must tell it from a client, as `examples/tcp-proxy` does.

### Shutdown

`tcp_request_shutdown`, or SIGINT or SIGTERM with `handle_signals`, stops accepting and begins a graceful
close of every connection: queued output is flushed, FIN is sent, and the connection lingers, reading and
discarding input, until the peer closes or `shutdown_grace_ms` ends. Lingering avoids the reset that closing
with unread input would cause, so the peer receives all the bytes sent before the stop. The loop returns
after the last connection closes or the grace ends, and `web::tcp_serve` returns `true`.

### Examples

`examples/tcp-echo` echoes bytes. `examples/tcp-chat` is a line-based room with `/nick` and `/quit`.
`examples/tcp-proxy` forwards each client to one numeric upstream address with backpressure on both
sides. Each has a README with `nc` commands. The test fixture `tests/fixtures/tcp.goose` runs the echo,
line, and frame modes plus a client mode used by `tests/integration/tcp.py`.

### Limits

- IPv4 and IPv6 literals only; no name resolution in the loop.
- No UDP, no TLS (put a TLS proxy in front; see the ROADMAP).
- One TCP loop and one HTTP reactor per process; hosting both in one loop is a follow-up (see
  [architecture.md](architecture.md#tcp-layer)).

## JSON codec

`src/json/codec.goose` maps structs to compact JSON objects and back, from `fields<T>`.
Field names are emitted as declared, in declaration order, with no whitespace.

- `json_encode(out, value) -> bool` appends to a growable `u8[>..]`. `value` is a struct (by
  value), or a scalar or literal string at top level. Strings must be valid UTF-8; otherwise
  it returns false and `out` is unchanged. Bytes are escaped per the stdlib writer.
- `json_decode<T>(text) -> T, DecodeResult` is strict: unknown keys, duplicate keys, wrong
  types, out-of-range integers, overlong strings, full arrays, invalid UTF-8 and trailing
  input are errors. Escapes are decoded before the check, so `\uD800` (an unpaired surrogate) decodes to bytes
  that are not UTF-8 and is refused as `invalid UTF-8 in string`. Missing keys keep the declared defaults (`T { .. }`).
- `DecodeResult { ok, syntax, error: u8[..128], field: u8[..64], present: u64 }`. `syntax`
  is true when the text is not JSON at all (map to 400); other errors are schema problems
  (map to 422). `field` is the key where the first error occurred. `present` bit i is set
  for top-level field i in declaration order; nested objects do not set bits.
- `has<T>(result, name) -> bool` reports whether top-level field `name` was present.

| Type | Encodes as | Decodes from |
|---|---|---|
| `i8`..`i64`, `u8`..`u32` | number | integer, within the width |
| `u64` | number | integer up to `i64` max; above that is rejected |
| `f32`, `f64` | number | any number; NaN and infinities encode as `null` |
| `bool` | `true` or `false` | `true` or `false` |
| `u8[..N]`, `u8[>..]`, `u8[]`, `const u8[:]` | string | string, into `u8[..N]` only |
| `T[..N]` (limited) | array | array, at most N elements |
| `T[N]`, `T[>..]`, slices | array | not decodable (no capacity: see below) |
| structs | object | object, via registration (below) |

A `u8` array is always a string, never an array of numbers. `f32` encodes its f64 value, so
`0.1f32` writes `0.10000000149011612`. Structs with more than 64 fields abort at decode.

Nested structs need one overload per direction in namespace `web`, because Goose cannot
tell a struct from a limited string in the generic path:

```goose
fn web::json_put_value(out: u8[>..]&, v: Inner&) -> bool { return web::json_put_fields(out, v); }
fn web::json_read_value(d: web::JsonDecoder&, out: Inner&) { web::json_read_fields(d, out); }
```

Decoding is limited to limited arrays and strings, because the decoder needs a capacity to
bound untrusted input; fixed and grow arrays can be encoded but not decoded.

Decoding runs in two passes: a syntax pass over the whole text, then the typed pass. So
errors found in the second pass are never syntax errors.

## Field names and skipping

The codec, `query<T>` and OpenAPI take each field's JSON name and whether it is kept from two
hooks in namespace `web`. Both are keyed by the declared field name from `fields<T>`:

```goose
struct Todo { id: i64, completed: bool, secret: u8[..16] }
fn web::json_key(v: Todo&, field: const u8[:]) -> const u8[:] {        // V's @[json: name]
    if field == "completed" { return "done"; }
    return field;
}
fn web::json_skip(v: Todo&, field: const u8[:]) -> bool { return field == "secret"; }   // V's @[skip]
```

- The defaults are generic: `json_key` returns the declared name and `json_skip` returns false. An
  application overload for its struct wins (a concrete overload beats the generic one).
- They apply to `json_encode` and `json_put_fields`, to `json_decode`, `body<T>` and `body_result<T>`,
  to `query<T>` and `query_result<T>`, and to the OpenAPI property names and query parameters. A nested
  struct written by its registration (`json_put_fields`) uses its own hooks.
- A skipped field is never encoded. On decode and in a query it is an unknown key, as if the struct did
  not declare it, and it is left out of OpenAPI schemas and query parameters.
- A renamed field is only known by its JSON name: the declared name is an unknown key. `has<T>(result,
  "completed")` and `present` still use the declared name, so PATCH handlers keep the same code.
  `optional_fields` in the OpenAPI registration also lists declared names.
- The SQLite layer does not use the hooks: its columns keep the declared names. A nested struct stored as
  JSON in a column does use them, so a skipped field is not written to that column.

Renamed names must be unique within a struct. `check_json_keys<T>() -> bool` checks this at startup,
and `json_key_report<T>(out: u8[>..]&) -> bool` appends `duplicate JSON key: NAME` to `out` on a conflict. At
use, encode returns false and leaves `out` unchanged, decode fails with `duplicate JSON key name` (422 from
`body<T>`), and `query<T>` answers 400 `invalid_query`. OpenAPI generation aborts, since it is a programmer
error in the documented struct.

## Application API

The app layer (`src/app/`) is built only on the calls above. An app is one function over
`web::Ctx&`, served with `web::run(config) { c => app(c) }`. Application code in the global
namespace calls these through `c.name(...)` (UFCS); `src/app/dsl.goose` forwards each name
there. Inside namespace `web` call `web::name(c, ...)` directly.

### Ctx accessors

| Call | Meaning |
| --- | --- |
| `c.method()`, `c.path()`, `c.target()`, `c.header(name)` | request views |
| `c.param(name)`, `c.param_int(name)` | path parameter; `param_int` writes 422 `invalid_param` on failure |
| `c.param_u64(name)` | canonical unsigned 64-bit decimal; 422 `invalid_param` otherwise |
| `c.param_uuid(name)` | `u8[..36]`, 8-4-4-4-12 hex digits, all lowercase or all uppercase; returned as sent; 422 `invalid_param` otherwise |
| `c.param_slug(name)` | `u8[..64]`, 1 to 64 bytes of `a-z`, `0-9` and `-`; 422 `invalid_param` otherwise |
| `c.peer()` | numeric client address (IPv4 or IPv6 text, no port); `""` for a `Request` built by hand |
| `c.query(key)`, `c.query_int(key, default)` | query value; `query_int` writes 400 `invalid_query` on failure |
| `c.status(code)` | sets the status and returns `Ctx&` for chaining |
| `c.set(name, value)` | response header (asserts on an invalid header) |
| `c.text(s)`, `c.html(s)`, `c.json_raw(s)` | content type and body; over capacity → 500 `response_too_large` |
| `c.json(value)`, `c.json_list(items)` | JSON responses (below) |
| `c.body<T>()` (see below) | request body; written as `body<T>(c)` |
| `c.no_content()`, `c.redirect(location, code)`, `c.redirect_local(target, code)`, `c.fail(status, code, message)` | responses; `redirect_local` accepts only a local absolute path (anything else is 400 `invalid_redirect`), so use it for targets taken from a request |
| `c.done()` | true once a response was written; middleware can short-circuit on it |

`c.body<T>()` is spelled `body<T>(c)`: the parser does not accept explicit type arguments on a
UFCS call. `c.request_id` is a `Ctx` field, so the middleware is called as `request_id(c) { }`.

### Routing DSL

`c.routes() { ... }` runs its block twice:

1. *Match pass.* Each `c.get/post/put/patch/delete/head/options/any(pattern) { }` records
   whether `prefix + pattern` matches the path. Route bodies do not run.
2. The best route is selected with the rules in `router.goose`. No path match → 404
   `not_found`. A path match without the method → 405 `method_not_allowed` with `Allow`.
3. *Dispatch pass.* The block runs again. Only the selected route's body runs, with path
   parameters bound.

Consequences:

- Code in `c.routes() { }` outside a route body runs twice. Keep it declarative: route calls,
  `c.group(prefix) { }`, and functions that declare routes.
- Routes are matched by declaration order, so both passes must declare the same routes. Do not
  branch on mutable state between passes.
- `return` inside a route body leaves the enclosing named function, which ends that route.
- Invalid patterns abort with the pattern in the message.
- **Wildcards.** A final segment `*name` takes the rest of the path, slashes included:
  `c.get("/files/*path")` matches `/files/a/b.txt` with `c.param("path") == "a/b.txt"`. The rest
  must be nonempty (`/files/` is a 404), is not decoded, and `*name` must be the last segment.
  Static segments and `:name` at the same position both win over `*name`, and a method missing
  on the winning shape is still 405, as with any other route. OpenAPI renders it as `{name}`.
- **Host scopes.** `c.host("api.example.com") { ... }` and `c.host("*.example.com") { ... }` limit
  the routes inside them to a Host header. The port is stripped, and the comparison ignores ASCII
  case. `*.example.com` matches exactly one label before `.example.com`. Scopes do not nest. The
  path shape is chosen first; host scope only breaks ties (exact, then wildcard, then unscoped).
  When no scoped or unscoped route matches the host, the answer is 404 (or 405, for a method that
  is registered for the path on that host). A request without a Host header matches unscoped
  routes only. OpenAPI documents scoped routes like any others and does not record the host.

### Middleware

Middleware is `fn name<Next>(c: Ctx&, ...) { before; Next(); after; }`. Not calling `Next()`
short-circuits. Nesting gives the order: the outer middleware's `before` runs first, and its
`after` runs last.

| Call | Behavior |
| --- | --- |
| `request_id(c) { }` | next value of a process-global counter, stored in `c.request_id` and sent as `X-Request-ID` |
| `logger(c) { }` | after `Next`, prints one line: `METHOD path status bytes`; control bytes are masked |
| `cors(c, origin = "*") { }` | sets `Access-Control-Allow-Origin` (plus `Vary: Origin` for a non-wildcard origin). A preflight (OPTIONS with `Access-Control-Request-Method`) gets 204 with Allow-Methods, Allow-Headers (echoes the request's headers when valid, else `Content-Type`) and `Max-Age: 600`, and `Next` is not called |
| `require_json(c) { }` | 415 `unsupported_media_type` unless the media type is `application/json` (parameters ignored, case-insensitive). It applies to every request in its block, so wrap body-carrying routes |
| `rate_limit(c, limit, window_ms) { }` | fixed window per client address (`c.peer()`): at most `limit` requests per `window_ms`. A refused request gets 429 `rate_limited` with `Retry-After` in whole seconds. Each `(limit, window_ms)` pair counts separately. The table is process-wide and bounded at 1024 clients; when it is full, the least recently seen client is recycled. Requests with no known peer share one bucket. With the shared store on (the default), every worker of one server counts into the same window, so the limit holds across workers; with it off, each worker counts alone. Separate server instances never share a count |
| `secure_headers(c, content_security_policy = "default-src 'self'", hsts = "") { }` | sets `X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY`, `Referrer-Policy: strict-origin-when-cross-origin` and `Content-Security-Policy` (an empty policy leaves it unset). `Strict-Transport-Security` is sent only when `hsts` is nonempty. Headers are set before `Next`, so a handler can replace one with `c.set`. The default policy blocks the CDN script on the `/docs` page, so wrap that page with `""` or a policy that allows it |

The runtime fills `Request.peer` from `getpeername` when it accepts a connection
(`gw_peer_address` in `native/posix/transport.c`). It is the TCP peer, never a forwarded header,
so behind a proxy every client shares the proxy's address.
| `session(c, config) { }` | loads the signed session cookie, exposes `session_get`/`session_set`/`session_clear`, and re-issues the cookie after the block only when the store changed. See [Sessions](#sessions) |
| `csrf(c, secret, check_origin = false) { }` | safe methods pass and receive a token cookie; unsafe methods need the token echoed in `X-CSRF-Token` or `csrf_token`, else 403 `csrf_failed`. See [CSRF](#csrf) |
| `basic_auth(c, realm, check) { }` | HTTP Basic: `check(user, password)` is a named function returning bool; a true result stores the user for `c.auth_subject()` and runs the block; anything else is 401 with a `WWW-Authenticate` challenge. See [Authentication](#authentication) |
| `bearer_auth(c, secret) { }` | `Authorization: Bearer` token verified with `verify_token`; the subject is stored like `basic_auth`; otherwise 401 `unauthorized`. See [Authentication](#authentication) |

| `live_reload(c, script_url = "") { }` | development only: after the block, a `text/html` response gets `<script src="URL"></script>` before its last `</body>` (appended when there is none). The URL is `script_url`, or else `GOOSE_WEB_LIVE_RELOAD`, read once per process. Unset, empty or unsafe means no change. See [Development server and live reload](#development-server-and-live-reload) |

### JSON responses and request bodies

- `c.json(value)` encodes a struct or scalar, passed by value, and keeps the status already set
  by `c.status()` (default 200). It sends `application/json`. Failures: over capacity → 500
  `response_too_large`; invalid UTF-8 → 500 `encode_error`.
- `c.json_list(items)` encodes an array or slice as a JSON array. Use it for arrays and slices;
  `c.json` on an array does not compile. A `u8` slice is text.
- `body<T>(c) -> T, bool` decodes the body strictly. `body_result<T>(c) -> T, DecodeResult`
  also returns the decoder result (`has<T>(result, "field")` for PATCH). On failure the error
  response is already written:

| Failure | Status | Code |
| --- | --- | --- |
| media type is not `application/json` | 415 | `unsupported_media_type` |
| empty body | 400 | `invalid_json` |
| not JSON, or invalid UTF-8 | 400 | `invalid_json`, message "Malformed JSON: ..." |
| schema error | 422 | `invalid_payload`, message "field: error" |

Nested structs must be registered in namespace `web`, once for encoding (`c.json_list`) and once
for decoding (`body<T>`):

```goose
fn web::json_put_value(out: u8[>..]&, v: Item&) -> bool { return web::json_put_fields(out, v); }
fn web::json_read_value(d: web::JsonDecoder&, out: Item&) { web::json_read_fields(d, out); }
```

### Typed query strings

`query<T>(c) -> T, bool` binds the decoded query into struct `T` by field name, using the same
reflection as `body<T>`. `query_result<T>(c) -> T, DecodeResult` returns the decoder result
instead (`has<T>(result, "field")` tells whether a key was present).

```goose
struct Search { limit: i32 = 10, q: u8[..32] = "", active: bool = false, score: f64 = 0.0 }

c.get("/search") {
    let s, ok = query<Search>(c);     // called as a plain function, not c.query<Search>()
    guard ok else { return; }
    c.json(s);
};
```

Rules, matching `body<T>`:

- Missing keys keep the declared default. Unknown keys and duplicate keys are errors.
- Keys and values are decoded with `query_decode` (percent escapes, `+` as space). Empty pairs
  (`a=1&&b=2`, a trailing `&`) are skipped.
- Field types: `i8`..`i64`, `u8`..`u64`, `bool`, `f32`, `f64`, `u8[..N]`. Integers are canonical
  decimal: optional leading `-` (signed types only), no `+`, no leading zeros, range-checked.
  `bool` accepts `true`, `false`, `1`, `0`. Strings must be valid UTF-8 and fit `N` bytes.
- Failure writes 400 `invalid_query` with the message `field: reason`, for example
  `limit: integer out of range`, `q: string too long`, `zzz: unknown key`, or
  `limit: duplicate query parameter`. A key that is not valid UTF-8 gets a fixed message.
- Keys are the JSON names from `json_key`; a skipped field is an unknown key (see [Field names and skipping](#field-names-and-skipping)).
- Other struct field types are not supported.

### Forms

`form<T>(c) -> T, bool` binds an `application/x-www-form-urlencoded` body into struct `T`, with the
same field types and rules as `query<T>`. It is called as a plain function, like `query<T>`.

```goose
struct NewTodo { title: u8[..64] = "" }

c.post("/todos") {
    let form_value, ok = form<NewTodo>(c);
    guard ok else { return; }           // 415 or 400 invalid_form is already written
    c.redirect("/", web::HTTP_SEE_OTHER);
};
```

- A `Content-Type` whose media type is not `application/x-www-form-urlencoded` (parameters such as
  `charset` are ignored, case-insensitive) writes 415 `unsupported_media_type`.
- Pairs follow the query rules: unknown and duplicate keys are errors, missing keys keep their
  defaults, an empty body binds all defaults, and `+` decodes to a space.
- A bad pair writes 400 `invalid_form` with the message `field: reason`, for example
  `zzz: unknown key` or `title: string too long`.
- The body is read from the request as received; `form<T>` does not accept multipart data.

### Cookies

`c.cookie(name) -> const u8[:]` returns the value of the first cookie with that exact name in the
request's `Cookie` header, or `""` when absent. Pairs are split on `;`, surrounding SP/HTAB is
trimmed, a DQUOTE-wrapped value is unwrapped, and a pair without `=` is ignored. Only the first
`Cookie` header is read. Values come back as sent, so an invalid cookie octet is visible to the caller.

`c.set_cookie(name, value, opts = CookieOptions { .. }) -> bool` appends one `Set-Cookie` line.
Each call adds a header, so several calls produce several `Set-Cookie` lines (see
`append_header` under HTTP and headers). It returns `false`, and changes nothing, when:

- `name` is not an RFC 7230 token, or `value` has a byte outside RFC 6265 cookie-octet
  (spaces, `"`, `,`, `;`, `\`, controls and non-ASCII are refused);
- `path` is non-empty and not an absolute path, or contains a control or `;` (an empty `path`
  omits the attribute);
- `same_site` is not `Strict`, `Lax`, `None` or empty (matched case-insensitively), or it is
  `None` without `secure`;
- the line does not fit the 256-byte header value capacity or the header count is full.

```goose
struct CookieOptions {
    path: u8[..64] = "/",
    max_age: i64 = -1,        // negative omits Max-Age; 0 asks the client to delete now
    http_only: bool = true,
    secure: bool = false,
    same_site: u8[..8] = "Lax",    // "" omits SameSite
}

c.post("/login") {
    let ok = c.set_cookie("session", token, web::CookieOptions { max_age: 3600, secure: true, same_site: "Strict" });
    guard ok else { return; }
    c.no_content();
};
```

Struct literals name fields in declaration order (`path`, `max_age`, `http_only`, `secure`,
`same_site`). Leave fields out to keep their defaults.

### Sessions

`session(c, config) { next }` is middleware for a small signed key/value store that lives in the
client's cookie. The store holds up to 16 entries: keys of at most 32 bytes and values of at most
256 bytes. The store is loaded before `next` runs, and the cookie is written again after it, but
only when the handler changed the store.

```goose
const SESSION_SECRET = "...";   // at least 32 bytes, from configuration (see Security notes)

fn app(c: web::Ctx&) {
    session(c, web::SessionConfig { secret: SESSION_SECRET }) {
        c.routes() {
            c.post("/login") {
                if !c.session_set("user", "alice") { c.fail(web::HTTP_CONFLICT, "session_full", "Session full"); return; }
                c.no_content();
            };
            c.get("/me") { c.text(c.session_get("user")); };
            c.post("/logout") { c.session_clear(); c.no_content(); };
        };
    };
}
```

`web::SessionConfig` fields, in declaration order (leave fields out to keep their defaults):

| Field | Default | Meaning |
| --- | --- | --- |
| `secret` | none | Signing key, at least 32 bytes. The middleware asserts this at start |
| `cookie` | `"gw_session"` | Cookie name, a token |
| `max_age` | `86400` | Seconds from the last change. Sent as `Max-Age` and enforced by the server |
| `secure` | `false` | Adds `Secure`. Required when `same_site` is `None` |
| `same_site` | `"Lax"` | `Strict`, `Lax` or `None` (not empty) |
| `store` | `false` | `true` keeps the session in the [shared store](#shared-store) instead of the cookie. The cookie then holds a random id and a tag, and the record lives for `max_age` seconds. Needs `shared_store_bytes` > 0 |

`HttpOnly` is always set and `Path=/` is always sent.

In store mode (`store = true`) the cookie is `id.tag`, where the tag is an HMAC of the id under the
secret, so a client cannot name a record it was not issued. The record holds the same entries as the
cookie mode, but its payload is one shared-store value, at most 1024 bytes, so the session holds less
data. Each change writes the record and re-issues the cookie with the same id; `session_clear` (logout)
deletes it. A record that is missing or expired gives an empty session. When the write fails (the table
is full), the response keeps the previous cookie and the change is lost, so check the `session_set`
result if that matters. A server restart clears every server-side session.

- `c.session_get(key) -> const u8[:]` returns the value, or `""` when the key is absent or no
  session middleware runs.
- `c.session_set(key, value) -> bool` stores a value and returns `false`, leaving the store
  unchanged, when there is no session middleware, the key is empty or longer than 32 bytes, the
  value is longer than 256 bytes, the store is full (16 entries and a new key), the payload would
  exceed 2816 bytes, or the clock is unavailable. The bound keeps the whole `Set-Cookie` line under
  4096 bytes. Setting a key to the value it already has does not count as a change.
- `c.session_clear()` removes every entry. The response then carries an expiring cookie
  (`Max-Age=0`).

Behavior: a missing, tampered, expired or future-dated cookie gives an empty session, without an
error. The server does not expire such a cookie; the browser drops it at `Max-Age`. A changed store
gets a new issue time, so the expiry is measured from the last change, not sliding on each request.

Cookie format: `base64url(payload) "." base64url(tag)`, where
`tag = HMAC-SHA256(secret, "gw-session|" || base64url(payload))`. The payload, before base64url,
holds a version byte (1), the issue time as 8 big-endian Unix seconds, the entry count, and for each
entry a key length (1 byte), the key, a value length (2 bytes, big-endian) and the value. Parsing
checks every length against its bound, refuses duplicate keys and any trailing bytes, and the tag is
compared in constant time before the payload is read. Issue times more than 60 seconds ahead of the
server clock are refused.

Security notes:

- **Signed, not encrypted.** The payload is base64url text, so the client can read every key and
  value. Store identifiers and small flags, not secrets or personal data that the client must not
  see. Keep sensitive state on the server and put only its key in the session.
- **Integrity, not revocation.** The HMAC stops forged or edited cookies. It does not stop replay:
  a copy of a cookie stays valid until `max_age` runs out, even after `session_clear()` on another
  request. For logout that must take effect at once, shorten `max_age` or rotate the secret, which
  invalidates every session.
- **Secret management.** Use at least 32 random bytes (for example `openssl rand -base64 48`),
  supplied through the environment or a secret store, never committed to source. One secret is in
  use at a time: rotating it signs everyone out, which is the intended incident response. Use
  different secrets for different deployments.
- **Transport.** Set `secure = true` in any deployment served over HTTPS, so the cookie never
  travels in clear text. `SameSite=Lax` is the default; `Strict` suits admin-only areas.

### CSRF

`csrf(c, secret, check_origin = false) { next }` protects unsafe methods against cross-site form
posts. It uses the double-submit pattern with an authenticated token, as in V's `veb.csrf`:

- Safe methods (GET, HEAD, OPTIONS) pass to `next`. If the request has no valid token cookie, the
  response sets one.
- Unsafe methods (POST, PUT, PATCH, DELETE and others) need the cookie token echoed back in the
  `X-CSRF-Token` header, or in a `csrf_token` field of an `application/x-www-form-urlencoded` body.
  Otherwise the response is `403` with the error code `csrf_failed`, and `next` does not run.
- With `check_origin = true`, an `Origin` header must name the same host as `Host` (the scheme is
  ignored). Without `Origin`, a `Referer` must. A request with neither is allowed, because the token
  still applies. An opaque origin such as `null` is refused.

`c.csrf_token() -> const u8[:]` returns the token for this request, for hidden form fields.

```goose
c.get("/form") {
    csrf(c, CSRF_SECRET) {
        c.html(str("<form method=post><input type=hidden name=csrf_token value=\"", c.csrf_token(),
                   "\"><button>Save</button></form>"));
    };
};
c.post("/form") { csrf(c, CSRF_SECRET, true) { c.text("saved"); }; };
```

Token format: `base64url(nonce) "." base64url(tag)`, 87 bytes, where the nonce is 32 bytes from the
CSPRNG (`getrandom(2)`, then `/dev/urandom`) and `tag = HMAC-SHA256(secret, "gw-csrf|" || base64url(nonce))`.
The cookie is `gw_csrf`, with `Path=/`, `HttpOnly` and `SameSite=Lax`. A token is not tied to a user
or a session, and it does not expire before the browser drops the cookie. Token comparison is
constant-time, and the form field is compared as sent, so clients should not percent-encode it (the
token uses only URL-safe characters).

Security notes:

- Only a server-made token passes: a cookie that an attacker plants fails the tag check. The tag
  uses its own label, so a session tag can never be replayed as a CSRF token.
- Use one secret for each purpose, or the same secret with these labels; the labels separate the two
  uses. The same secret rules as for sessions apply.
- The CSRF cookie carries no `Secure` attribute in this version. Serve forms over HTTPS: an
  attacker who can read HTTP traffic can read and replay tokens.
- CSRF protects state-changing methods only. Do not change state on GET, HEAD or OPTIONS.
- `multipart/form-data` bodies are not parsed. Send the token in `X-CSRF-Token` from such forms,
  through script, or use a URL-encoded form.

### Authentication

Password hashing, HTTP Basic and Bearer middleware, and HMAC-signed tokens. The design and the
threat model are in [Security](security.md#password-hashing).

```goose
const ALICE_HASH = "$pbkdf2-sha256$600000$...";     // from web::hash_password, stored by the app

fn check_login(user: const u8[:], password: const u8[:]) -> bool {
    return user == "alice" && web::verify_password(password, ALICE_HASH);
}

c.get("/admin") {
    c.basic_auth("Admin", check_login) {
        c.text(c.auth_subject());    // the verified user, "alice"
    };
};
```

Password hashes (namespace `web`):

- `hash_password(password) -> u8[..128], bool` hashes with PBKDF2-HMAC-SHA256 (RFC 8018), 600000
  iterations and a 16-byte salt from the CSPRNG. The result is
  `$pbkdf2-sha256$<iterations>$<salt base64url>$<hash base64url>`, unpadded base64url. The bool is
  false only when no random source answers, and then nothing is returned.
- `hash_password_iterations(password, iterations) -> u8[..128], bool` uses an explicit count,
  1 to 10000000. Counts below the default weaken the hash; they are for tests.
- `verify_password(password, encoded) -> bool` compares the derived key with the stored hash in
  constant time. It reads the count and salt from the hash, so old hashes keep working when the
  default changes. A malformed, unsupported or over-limit encoding returns false.

Middleware (`c.basic_auth(...)`, `c.bearer_auth(...)`, or `web::basic_auth(c, ...)` inside namespace
`web`):

- `basic_auth(c, realm, check) { next }` reads `Authorization: Basic`, decodes the standard base64
  credentials and splits them at the first `:`. `check` is a named function
  `fn(user: const u8[:], password: const u8[:]) -> bool`, passed after the realm. When it returns
  true, the user is stored for `c.auth_subject()` and `next` runs. Otherwise the response is 401
  `unauthorized` with `WWW-Authenticate: Basic realm="...", charset="UTF-8"`, and `next` does not
  run. The realm is printable text of at most 128 bytes without `"` or `\`; a bad realm is a
  programmer error (assert). Users over 64 bytes are refused.
- `bearer_auth(c, secret) { next }` reads `Authorization: Bearer <token>` (scheme compared
  case-insensitively), verifies the token with `verify_token`, stores the subject, and runs `next`.
  Otherwise it answers 401 `unauthorized` with `WWW-Authenticate: Bearer` (no token given) or
  `Bearer error="invalid_token"`. `secret` must be at least 32 bytes.
- `c.auth_subject()` returns the subject that a verifying middleware stored, or `""` when none did.
  A handler behind no middleware never sees a subject, so an empty result means "not verified".
- `bearer_token(c)` returns the raw token text without verifying it. Do not trust it on its own.

Signed tokens (namespace `web`), for APIs that issue bearer credentials:

- `sign_token(secret, subject, ttl) -> u8[..256], bool` makes a token for `subject` (1 to 64 bytes)
  valid for `ttl` seconds (1 to 315360000) from now. It refuses a secret under 32 bytes and an
  unavailable clock, and then returns false with an empty token.
- `verify_token(secret, token) -> u8[..64], bool` returns the subject when the token is well formed,
  correctly tagged, not expired, and not issued more than 60 seconds in the future. `verify_token_at`
  takes the clock as an argument, for tests.

The token is `base64url(payload) "." base64url(tag)`, with
`tag = HMAC-SHA256(secret, "gw-token|" || base64url(payload))`. The payload is a version byte (1),
the issue time, the expiry time (each 8 bytes, big-endian Unix seconds) and the subject. It is not
JWT, deliberately: there is no algorithm field for a verifier to trust, so `"alg": "none"` and
key-confusion attacks have nothing to act on. Tokens are bearer credentials. There is no revocation;
keep `ttl` short, and rotate the secret to sign everyone out.

Password verification is CPU-bound: each check runs the full iteration count. The unit suite's
default-count hash and verify take a few seconds in its unoptimized debug build; measure the cost on
the target hardware before choosing a count. Use `rate_limit` on login routes.

### Static files

`c.static_files(url_prefix, directory) { next }` is middleware. It serves GET and HEAD requests under
`url_prefix/` from `directory`, and otherwise calls `next` (the routes that follow it). Put it
inside `request_id`, `logger`, and `cors` so the headers and log lines apply to file responses.

```goose
c.static_files("/static", "public") {
    c.routes() { ... };
};
```

It was chosen over a route kind because the router has no wildcard segment, and a middleware keeps
the matching rule in one place. The consequences are part of the contract:

- Any GET or HEAD under the prefix is owned by the middleware. A missing file answers 404
  `not_found` without calling `next`, so GET routes under the same prefix are shadowed.
  Other methods under the prefix fall through to the routes.
- `url_prefix` must start with `/`; a trailing `/` is ignored. `directory` is trusted configuration
  and must be nonempty. Its relative path is resolved from the process working directory.

Mapping and refusals (the path after the prefix is percent-decoded and checked segment by segment):

| Request | Result |
| --- | --- |
| `/static/` or a directory such as `/static/docs` | its `index.html`, or 404 when there is none |
| `/static/a%20b.txt` | file `a b.txt` |
| `..` or `.` segment, raw or encoded (`%2e%2e`) | 400 `invalid_path` |
| encoded `/`, `\`, NUL or a control byte (`%2F`, `%5C`, `%00`, `%0a`), raw `\` | 400 `invalid_path` |
| empty segment (`//`, leading `/`), truncated or invalid `%` escape | 400 `invalid_path` |
| a segment starting with `.` (dotfiles, `.git`) | 404 `not_found` |
| missing file | 404 `not_found` |

Content-Type comes from the extension, case-insensitively: `html`/`htm`, `css`, `js`/`mjs`,
`json`, `svg`, `png`, `jpg`/`jpeg`, `gif`, `ico`, `txt`, `wasm`. Anything else, including no
extension, is `application/octet-stream`. Served files also carry `X-Content-Type-Options: nosniff`.
Do not serve untrusted uploads from the directory: an `svg` or `html` file runs with the
application's origin.

Size and blocking: the file is read on the reactor thread, so no request is served while that
happens. Each read is bounded before any byte of the file is copied:

1. `stat` reports the regular file's size. A size over the response's `max_body` (the configured
   `max_response_bytes`, default 1 MiB) is refused with 500 `file_too_large` and the file is never read.
2. Otherwise the reader asks for `size + 1` bytes (the spare byte detects a file that changed
   during the read). The count must equal the stat size; any other count is a failed read.
3. A missing entry, directory, FIFO or other non-regular file is 404 `not_found`. A file that
   exists but cannot be opened or read, or that changed size during the read, is 500
   `file_read_failed`. Before this change these cases answered 404.

Keep served trees small and trusted, or serve
large assets elsewhere. Symbolic links are followed only when their real target lies inside the
directory; a link that leaves it answers 404 `not_found` and its target is never read.

The framework reads files and the environment through `src/sys/`, not the `os` stdlib. Importing
`os` into framework code made its global names (`read_file`, `is_dir`, `clock_ns`, ...) ambiguous
for every application that imported `goose_web`. Applications may use `os` freely.

## Templates

HTML templates are compiled into the program. A template is bytes, normally
`embed_file("views/page.html")`, which is read at compile time relative to the source file that
makes the call, so a missing file is a compile error. `examples/pages` shows the full pattern: a
shared layout, partials, flash messages, forms with CSRF tokens and validation.

```goose
struct Todo { id: i64, title: u8[..64], done: bool }
struct ListPage { meta: web::PageMeta, todos: Todo[..32] }

// main: partials are registered once, then the layout and page are checked together.
var views = web::templates();
web::add_template(views, "nav", embed_file("views/_nav.html"));
let valid, problem = check_template<ListPage>(embed_file("views/layout.html"), embed_file("views/list.html"), views);
if !valid { print(problem[..]); abort("views are not valid templates"); }

// route: a page inside the layout; a render failure writes 500 template_error with the reason.
c.get("/") {
    c.html_page(views, embed_file("views/layout.html"), embed_file("views/list.html"),
        ListPage { meta: web::page_meta(c, "Todos"), .. });
};
```

### Grammar

Tags are `{{` ... `}}`; whitespace around a name is ignored.

| Tag | Output |
| --- | --- |
| `{{name}}` | the field's value; strings are HTML-escaped |
| `{{{name}}}` | the field's value, unescaped |
| `{{meta.title}}` | a field of a struct-typed field (dotted; see [Struct fields](#struct-fields)) |
| `{{#name}}...{{/name}}` | the body when the bool field `name` is true (dotted names work) |
| `{{^name}}...{{/name}}` | the body when the bool field `name` is false |
| `{{#each name}}...{{/each}}` | the body once per element of the array field `name`; names inside resolve against the element |
| `{{#each name}}...{{else}}...{{/each}}` | the `{{else}}` part when the array is empty |
| `{{@index}}`, `{{@count}}` | the element's position (from 0) and the array's length, inside `each` |
| `{{@first}}`, `{{@last}}` | `true` or `false`; `{{#@first}}...{{/@first}}` and `{{^@last}}` are sections |
| `{{$name}}...{{/name}}` | a named block: in a page it defines the block; in a layout it is a slot (see [Layouts](#layouts)) |
| `{{> name}}` | a partial from the registry, rendered with the current data (inside `each`, the element) |
| `{{> content}}` | in a layout only: the rendered page body |
| `{{! text }}` | a comment, dropped from the output |

- Scalars print as text: integers in decimal, `bool` as `true` or `false`, floats in JSON number
  form. `u8[..N]` fields print their bytes. Arrays of structs belong under `each`.
- Names are resolved at run time against the struct's fields. Errors: an unknown name, a section on
  a non-bool field, an `each` on a non-array, an unclosed or mismatched section, a stray closing
  tag, an empty tag, `@index` outside `each`, `{{else}}` outside `each`, `{{> content}}` outside a
  layout, an unknown partial, a partial that includes itself, a block defined twice on one page,
  invalid UTF-8, or nesting deeper than 8 levels (sections, `each` bodies and partials all count).
- Output past 1 MiB, the default response cap, is an error, and a body over the response's
  `max_response_bytes` becomes the usual 500 `response_too_large`.

### Layouts

`render_layout<T>(out, layout, page, data, partials)` and `c.html_page(partials, layout, page, data)`
render a page into a layout. The page's text outside its blocks is the body; the layout places it
with `{{> content}}`. A page defines blocks with `{{$name}}...{{/name}}`, which are not shown in the
page's own body. The layout has a slot `{{$name}}default{{/name}}` for each block: the page's block
of that name when it defines one, else the default. Page blocks are rendered with the same data as
the layout, outside any `each` loop.

```html
<title>{{$title}}Todo Pages{{/title}}</title>
<!-- page.html -->
{{$title}}Todo 1 - Todo Pages{{/title}}
Body text, placed at {{> content}} in the layout.
```

The layout can be used without the registry (`c.html_page(layout, page, data)`), which is the
same with no partials available.

### Partials

`web::templates()` makes an empty registry; `web::add_template(views, name, body)` adds a partial
(at most 32, each at most 64 KiB, names of 1 to 32 bytes without whitespace or tag markers, and
not `content`). It returns false, leaving the registry unchanged, when it is full, the name is
taken, or the body is invalid. Build the registry once, in `main`, before the server starts, and
pass it to `render`, `html_template`, `html_page`, and `check_template`. A global registry must
not hold borrowed slices of values the runtime clears; the example keeps `views` in `main` and
passes it to its handlers.

`{{> name}}` renders the partial with the data in scope, so one partial can serve the page and
each row of a list. A partial that includes itself, directly or through others, fails with
`partial includes itself: name`; a chain nested too deeply fails with `partials are nested too deeply`.

### Loops

Inside `{{#each name}}`, `{{@index}}` is the element's position, `{{@count}}` the array's length,
and `{{@first}}` / `{{@last}}` say whether it is the first or last one. The else part of an empty
`each` shows when there are no elements. Names inside the body resolve against the element, so a
row that needs an outer value (a CSRF token, say) copies it into the element.

### Struct fields

Goose cannot tell a struct from a fixed string inside one generic body, so a struct used as a field
of a template struct needs its own overloads in namespace `web`, the same way the JSON codec needs
its hooks (see [JSON codec](#json-codec)). Four overloads per struct type `S`:

```goose
fn web::tpl_show(out: u8[>..]&, v: S&, escape: bool) -> bool { return false; }        // not printable
fn web::tpl_each_value(out: u8[>..]&, body: const u8[:], v: S&, checking: bool, depth: i64,
    env: web::TplEnv&, count: i64&, result: web::TemplateResult&) -> bool {
    return web::tpl_fail(result, "each needs an array of structs");                  // not a list
}
fn web::tpl_show_sub(out: u8[>..]&, v: S&, tail: const u8[:], escape: bool,
    result: web::TemplateResult&) -> bool { return web::tpl_field(out, v, tail, escape, result); }
fn web::tpl_flag_sub(v: S&, tail: const u8[:], flag: bool&, result: web::TemplateResult&) -> bool {
    return web::tpl_flag(v, tail, flag, result);
}
```

The last two make dotted names work: `{{meta.title}}` reaches `S`'s `title` field through
`tpl_show_sub`, and `{{#meta.has_flash}}` through `tpl_flag_sub`. Without them, a dotted name fails
with `no registered struct for: name`. `web::PageMeta` is registered in `src/app/page.goose`. A
dotted name reaches fields one level at a time and works for values and sections, not for `each`.

### Page state

`web::PageMeta` is the state a layout needs: `title`, `csrf_token`, the flash message
(`flash_kind`, `flash_message`, `has_flash`), `path` and `user`. Put a `meta: web::PageMeta` field
in a page's data struct and fill it with `web::page_meta(c, title)`. The layout reads it as
`{{meta.title}}` and so on, and a form adds `<input type="hidden" name="csrf_token" value="{{meta.csrf_token}}">`.
`user` is the session value under the key `user`.

Flash messages live in the session (the session middleware must run). `c.flash(kind, message)`
stores one for the next page the client loads: `kind` names the style (no `|`, at most 16 bytes),
`message` is at most 200 bytes. `web::take_flash(c)` returns a `Flash { kind, message, present }`
and clears it, so it shows once. `page_meta` takes it for the page it builds, which is why a
redirect after a write carries its result to the next page.

### Functions

In namespace `web` (also reachable from the DSL as `c.html_template`, `c.html_page`, `check_template`):

- `render<T>(out, template, data) -> bool` and `render<T>(out, template, data, partials) -> bool`
  append the rendered text to `out`. On false, `out` is unchanged. `render_result` returns the
  reason in `result.error` (up to 128 bytes) as well.
- `render_layout<T>(out, layout, page, data, partials) -> bool` renders a page into a layout;
  `render_layout_result` also returns the reason.
- `html_template<T>(c, template, data)` and `html_template<T>(c, partials, template, data)` write
  `text/html; charset=utf-8`.
- `html_page<T>(c, layout, page, data)` and `html_page<T>(c, partials, layout, page, data)` write a
  page in a layout. A render failure writes 500 `template_error` with the reason.
- `check_template<T>(template) -> bool, u8[>..]` validates every tag and section against `T`,
  including the body of each `each` even when the array is empty. `check_template<T>(template,
  partials)` also checks the partials the template uses. `check_template<T>(layout, page, partials)`
  checks a page and its layout together, and each partial where it is used. A partial no template
  uses is not checked. Call one per page in `main`.
- `html_escape(out, text)` escapes `&`, `<`, `>`, `"` and `'` (as `&#39;`).

A template must be valid UTF-8; the output is served as `text/html; charset=utf-8`, so the
template and the escaped values decide what the browser sees. Escaping covers element content and
quoted attributes. Put untrusted text only in `{{name}}` tags, not in `{{{name}}}` or in script
or style contents.

## Command-line and environment configuration

`web::config_from_args(argv) -> ServerConfig, bool, u8[>..]` builds a configuration from `args()`
(argv[0] is the program name). On failure the bool is false and the message says what was wrong.

| Argument | Meaning |
| --- | --- |
| `[port]` | a bare first argument is the port (the original examples' form) |
| `--port N`, `--port=N` | 1..65535 |
| `--host public` or `--host loopback` | `public_bind` true (all IPv4) or false (127.0.0.1) |
| `--max-clients N` | 1..`MAX_CLIENTS` |
| `--max-requests N` | 0 unlimited; otherwise stop after N completed responses (per worker when `workers` > 1) |
| `--workers N` | 1 single process (default); 0 one worker per CPU; 2..256 that many worker processes |

Other arguments are errors: unknown options, a missing value, and a second bare argument. An
application that takes its own positional arguments passes only the prefix it owns; the basic
example passes `argv[..2]` and reads max-responses and the data file itself. Ranges are checked
by `validate_server_config`.

`web::config_from_env() -> ServerConfig, bool, u8[>..]` reads `GOOSE_WEB_PORT` (the `--port` rule)
and `GOOSE_WEB_PUBLIC` (`1` or `true` for public, `0` or `false` for loopback), and `GOOSE_WEB_WORKERS`
(the `--workers` rule). Unset and empty
variables keep the defaults. A value longer than 256 bytes is invalid.

```goose
fn main() {
    let config, ok, error = web::config_from_args(args());
    if !ok { abort(error); }
    let started = web::run(config) { c => app(c) };
    if !started { abort("server failed"); }
}
```

Blocking: each file is read whole with `read_file` on the reactor thread, and no request is
served while that happens. The `os` stdlib has no file size query, so the read itself is not
bounded by the response capacity. The response is: a body over `MAX_RESPONSE_BODY_BYTES` becomes
500 `response_too_large`. Keep served trees small and trusted, or serve large assets elsewhere.
Symbolic links are followed only when their real target lies inside the directory (see Static files).

### OpenAPI

`web::openapi(c, info) { c.routes() { ... } }` serves an OpenAPI 3.1 document at `info.json_path`
(default `/openapi.json`) and a Swagger UI page at `info.docs_path` (default `/docs`, loading a pinned
`swagger-ui-dist` build from cdn.jsdelivr.net). The document is generated from the same routes block:
the routes run once more in a *describe* pass in which no route body runs. The document paths are
answered only when `openapi` wraps the routes; otherwise they are ordinary 404s.

```goose
web::openapi(c, web::OpenApiInfo { title: "Todo API", version: "1.0.0", description: "..." }) {
    c.routes() {
        web::summary(c, "Create a todo");
        web::accepts<TodoInput>(c);                  // requestBody (application/json)
        web::returns<Todo>(c, web::HTTP_CREATED);    // response schema for one status
        c.post("/todos") { ... };
        web::query_params<ListParams>(c);            // query parameters from struct fields
        web::returns_list<Todo>(c, web::HTTP_OK);    // array response
        c.get("/todos") { ... };
    };
};
```

Annotations are plain calls placed before the route they describe. Outside the describe pass they do
nothing, so they cost normal requests nothing and may be used in any app. They attach to the next
route only:

| Call | Documents |
| --- | --- |
| `web::summary(c, text)` | operation summary |
| `web::tag(c, name)` | tag; default is the first segment of the enclosing `c.group` prefix |
| `web::accepts<T>(c)` | `requestBody` (`application/json`, required) from struct `T` |
| `web::returns<T>(c, status)` | response `status` with the schema of struct `T` |
| `web::returns_list<T>(c, status)` | response with an array of `T` |
| `web::returns_empty(c, status)` | response with no body (for example 204) |
| `web::query_params<T>(c)` | optional query parameters, one per field of `T` |

Generic calls are written in the non-UFCS form (`web::accepts<T>(c)`), since UFCS takes no explicit
type arguments (as with `body<T>(c)`).

Schemas are inline (no `$ref`), built from `fields<T>`:

- integers are `integer` with `minimum`/`maximum` for their width (`u64` up to `i64` max, as the
  codec accepts); `f32`/`f64` are `number`; `bool` is `boolean`.
- `u8[..N]` text is `string` with `maxLength: N`; other limited arrays are `array` with `maxItems: N`.
- A struct nested in another struct needs a registration in namespace `web`, next to its JSON one:

```goose
fn web::json_schema_value(out: u8[>..]&, v: Inner&) { web::json_schema_fields(out, v); }
```

- Every field is `required` unless the struct lists its optional fields with a registered hook (a
  comma list; Goose cannot see declared defaults, so this is explicit):

```goose
fn web::optional_fields(v: TodoInput&) -> const u8[:] { return "completed"; }
```

Each operation also documents the framework's error envelope (`{"error":{"code","message"}}`) for
400, 404, 405 (with `Allow`), 415, 422 and 500, unless the route declares that status itself.
Path parameters `:id` become `{id}` and are documented as required strings.

Limits, stated so they are not a surprise:

- Constraints beyond the width (for example `limit` is 1..8) are not expressible; write them in the
  `summary` or in the docs.
- One schema per request body. PUT and PATCH therefore use separate documentation structs when their
  required fields differ from POST's.
- `any()` routes have no OpenAPI method and are not documented.
- Annotation fragments are bounded (4 KiB per request body, responses or query parameters). Overflow
  aborts while `/openapi.json` is generated, which is a programmer error; the document itself must
  fit the response cap (`MAX_RESPONSE_BODY_BYTES`, 64 KiB today).
- The document is compact JSON with no whitespace and is regenerated per request.

## Development server and live reload

`scripts/dev.py` rebuilds a program when its files change and restarts it, and reloads the browser
page. It is a development tool, not part of the served application (standard library only).

```sh
python3 scripts/dev.py examples/pages/server.goose             # serve on 8080, reload endpoint on 8081
python3 scripts/dev.py server.goose --port 9000 --reload-port 9001 --watch ../shared
python3 scripts/dev.py server.goose -- --workers 2             # arguments after -- go to the program
```

| Option | Meaning |
| --- | --- |
| `--port N` | the port the program listens on (default 8080); it is passed as `--port N` before the program arguments |
| `--reload-port N` | the live reload endpoint (default `--port` + 1), bound to 127.0.0.1 |
| `--watch DIR` | another directory to watch (repeatable) |
| `--release` | build with `-O2` instead of `--debug` |
| `--goose PATH` | the compiler (default `$GOOSE`, then `goose`) |
| `--build-command CMD` | build with `CMD` instead of goose; `{source}` and `{output}` are replaced |
| `--polling` | poll the file tree instead of using inotify |

The program must read its arguments with `web::config_from_args(args())`, so the `--port` that dev.py
passes is understood. The page gets the reload script only from `web::live_reload`, so add it inside
the application's middleware (the starter and the pages example do).

**Watching.** The root file's directory tree, the goose_web package root (a local path in its
`import goose_web from "...";` line, such as `../..` in `examples/`) and each `--watch` directory are
watched. Files ending in `.goose`, `.html`, `.css`, `.js`, `.build`, `.json`, `.txt`, `.svg`, the image
types, `.yaml`, `.yml`, `.sql` and `.csv` count, so embedded assets (`embed_file`) are covered. The
directories `build/`, `__pycache__`, `node_modules` and hidden directories are skipped. On Linux the
watch uses inotify through ctypes; elsewhere, or when inotify is unavailable, the tree is polled every
0.25 s.

**Rebuilding.** A change starts a build after 150 ms without further changes (at most one second of
changes is batched). The build is `goose build SERVER -o build/dev/NAME-N --debug`, so each rebuild writes a
new binary and never overwrites a running one. A successful build stops the old server (SIGTERM, then
SIGKILL after five seconds), starts the new one, waits until it accepts connections (15 seconds at most),
and sends `reload`. A failed build prints the compiler output, keeps the running server answering, and sends
`error`. Ctrl+C stops the server and exits.

**Reload endpoint.** It listens on `127.0.0.1:RELOAD_PORT` with three paths: `/live.js` (the browser
script, with CORS allowed), `/events` (a `text/event-stream`) and `/` (a one-line status). The events are:

- `reload` with `{}`: the new server is listening; the browser calls `location.reload()`.
- `error` with `{"message": "..."}`: the build or the server start failed; the browser shows the message
  as an overlay. A browser that connects during a failure receives the last message at once.

The script uses `EventSource`, which reconnects by itself, so a browser keeps listening across a
restart of dev.py's reload endpoint without a manual refresh.

**The environment variable.** While dev.py runs the program, it sets `GOOSE_WEB_LIVE_RELOAD` to the
script URL (`http://127.0.0.1:RELOAD_PORT/live.js`). `web::live_reload` reads it once, on the first
request. Each text/html response the middleware sees gets the tag `<script src="URL"></script>` before its
last `</body>`; responses that are not `text/html`, server-sent event streams, and responses where the
insertion would exceed `max_response_bytes` are left as they are. A URL with spaces, quotes, angle brackets
or backslashes is ignored. Without the variable (a production start) the middleware only calls `Next()`.

```goose
fn app(c: web::Ctx&) {
    web::live_reload(c) {
        c.routes() {
            c.get("/") { render_home(c); };
        };
    };
}
```

**Limits.** The rebuild is a full `goose build`, so a change costs the compile time of the program
(a few seconds for the examples). Only one server runs at a time, and a process that exits by itself
is reported as `error` until a file changes. The reload endpoint has no authentication and listens on
loopback only; do not expose it or set `GOOSE_WEB_LIVE_RELOAD` in deployed environments.

## SQLite (web::db)

Opt-in package `db/` (`import goose_web_db from "../../db";` beside `import goose_web from "../..";`).
Its sidecar `db/goose_web_db.build` compiles `db/native/sqlite_shim.c` and links `sqlite3`; the core
framework links nothing new. Needs `sqlite3.h` and `libsqlite3` (Debian/Ubuntu: `libsqlite3-dev`).
Design: [app-api.md, v0.4](design/app-api.md#v04-design-reflective-sqlite-layer-webdb).

```goose
struct Todo { id: i64, title: u8[..200], completed: bool }
fn web::db_table(v: Todo&) -> const u8[:] { "todos" }      // required
// fn web::db_primary(v: Todo&) -> const u8[:] { "id" }    // optional; the key must be an i64 field

var database = default<web::Db>();
guard web::db_open(database, "build/app.db") else { abort(web::db_error(database)); }
web::create_table<Todo>(database);                          // CREATE TABLE IF NOT EXISTS
let id, ok = web::insert(database, item);                   // rowid; a zero key is assigned
let row, found = web::find_row<Todo>(database, id);         // found false + empty db_error: no row
web::update(database, row);                                 // by key; false + "no row ..." if absent
web::remove<Todo>(database, id);
let n = web::count<Todo>(database, web::where_eq(web::query(), "completed", false));
web::select<Todo>(database, web::limit(web::order_by(web::query(), "id", true), 20)) { row => list.push(row); };
let saved = web::transaction(database) { web::update(database, row) && web::remove<Todo>(database, 2) };   // see below
web::migrate(database, ["ALTER TABLE todos ADD COLUMN due INTEGER NOT NULL DEFAULT 0"]);
web::db_close(database);
```

| Call | Result |
| --- | --- |
| `db_open(db, path) -> bool` | `":memory:"` or a file; WAL journal, 5 s busy timeout. Fails if already open |
| `db_close(db)` | closes and finalizes the handle's statements; idempotent |
| `db_error(db) -> const u8[:]` | last SQLite message, at most 256 bytes; empty after success |
| `db_exec(db, sql) -> bool` | one statement with no values (DDL, `PRAGMA`); multi-statement text is refused |
| `create_table<T>(db) -> bool` | `CREATE TABLE IF NOT EXISTS` from `fields<T>` |
| `insert<T>(db, item) -> i64, bool` | every field; the key binds NULL when zero, so SQLite assigns the rowid |
| `update<T>(db, item) -> bool` | sets the non-key fields where key = item's key |
| `remove<T>(db, id: i64) -> bool` | deletes by key; false with `no row matches the primary key` when absent |
| `find_row<T>(db, id: i64) -> T, bool` | the row; a missing row is `false` with an empty `db_error` |
| `select<T>(db, q) { row => ... } -> bool` | calls the block per row, in `ORDER BY` order; false on a failed step or column |
| `count<T>(db, q) -> i64` | matching rows (order and limit ignored); `-1` on failure |
| `transaction(db) { ... } -> bool` | `BEGIN`, the block, `COMMIT` if it returns true, else `ROLLBACK` |
| `migrate(db, steps) -> bool` | applies `steps` in order, each with its version bump in one transaction |
| `identifier_valid(name) -> bool` | `[A-Za-z_][A-Za-z0-9_]*`, at most 63 bytes |

**Query builder.** `web::query()` starts a value of at most 8 conditions, one `order_by` and one
`limit`. Conditions: `where_eq`, `where_ne`, `where_lt`, `where_le`, `where_gt`, `where_ge`,
`where_like(q, column, value)`, AND-ed. `order_by(q, column, descending: bool)` and `limit(q, n)`.
Call them as functions (`web::where_eq(web::query(), ...)`): a UFCS chain is resolved in the caller's
namespace and does not find them. Values are bound as parameters, never spliced into SQL. Text values are
at most 256 bytes; a longer one, a ninth condition, a bad identifier or a negative limit is a builder
error reported by `count` (-1) and `select` (false). An unknown column in a query aborts: it is a
programmer error (`column_known<T>(name)` tests a name).

**Mapping.** Integers and `bool` are `INTEGER`, `f32`/`f64` are `REAL`, `u8[..N]` is `TEXT`.
Other arrays and nested structs are `TEXT` holding the codec's JSON. Reads are checked: an integer
outside the field's range, a text longer than `N`, a malformed or overlong JSON value, or a NULL are
errors (false, `db_error` set), never silent truncation. A `u64` above `i64` max cannot be written.
Primary keys are `i64` fields (`INTEGER PRIMARY KEY`).

Nested structs need the codec pair plus a SQLite pair (the JSON route):

```goose
fn web::json_put_value(out: u8[>..]&, v: Meta&) -> bool { return web::json_put_fields(out, v); }
fn web::json_read_value(d: web::JsonDecoder&, out: Meta&) { web::json_read_fields(d, out); }
fn web::sql_put_value(db: web::Db&, s: i32, index: i32, v: Meta&) -> bool { return web::sql_put_json(db, s, index, v); }
fn web::sql_read_value(db: web::Db&, s: i32, col: i32, out: Meta&) -> bool { return web::sql_read_json(db, s, col, out); }
```

The codec also needs `json_put_value`/`json_read_value` for an element of an array, such as the
`Todo` in a `c.json_list(todos[..])` response.

**NULL.** Every column is `NOT NULL`, and Goose fields are never null. A NULL in a table made outside
this layer is a read error. The one NULL this layer writes is the zero key on insert.

**Transactions.** The block's value decides: `true` commits, `false` rolls back, and a failing step
inside the block (its message is kept in `db_error`) makes the block false. A `return` inside a
transaction block skips `COMMIT`/`ROLLBACK`; do not use one there. Nested transactions are refused.

**Migrations.** `migrate` records how many steps ran in `schema_version`. Steps are append-only: a
step already applied is not re-run, and a database newer than the step list is an error.

**Blocking.** Every call runs on the reactor thread. Keep statements short, index columns you filter
on (`CREATE INDEX` through `db_exec`), and do not hold a `select` open across a slow handler.

**Errors.** The shim keeps a fixed table: 8 open databases and 64 statements. Each call clears
`db_error` first, so read it right after the call. `remove`, `update` and `find_row` report a
missing row with `false`; `find_row` alone leaves `db_error` empty for it.
