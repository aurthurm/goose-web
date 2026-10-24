# Scheduled work and background jobs

**Version:** The scheduler and job pool described here are on `main` and are not in the published
`v0.6.0` package. The code snippets are partial lifecycle fragments; see the full jobs example.

Use the scheduler for short, nonblocking work that can run on the reactor. Use a job pool for
longer CPU work that can run as pure Goose on worker threads. In both cases, HTTP handlers and
`tick` run synchronously on the reactor: slow work there pauses request processing.

## Scheduler

Create a scheduler and register task IDs during startup. Call `due` from `tick`; optionally call
`hint_wakeup` so the reactor wakes for the next deadline rather than waiting for its regular poll
interval. Periodic tasks run once when late; missed intervals are skipped, not replayed.

```goose
import goose_web from "../goose-web";
import std;
import os;

var control = default<web::ServerControl>();
var sched = web::scheduler();
var cleanup_count: i64 = 0;

fn cleanup_task(id: i64) { if id == 1 { cleanup_count += 1; } }
fn tick() {
    web::due(sched) { id => cleanup_task(id) };
    web::hint_wakeup(sched, control);
}
fn app(c: web::Ctx&) { c.routes() { c.get("/health") { c.text("ok"); }; }; }

fn main() {
    assert(web::every(sched, 1, 30000));
    var config = web::server_config();
    config.handle_signals = true;
    let started = web::run_with(config, control, app, tick, web::ignore_lifecycle);
    if !started { abort("server failed"); }
}
```

The example increments a counter as a placeholder for short, nonblocking cleanup. The scheduler
has 64 slots; IDs are app-chosen, and repeated IDs replace their schedule. For the scheduler contract,
see [API](../api.md#scheduler).

## Job pool

`job_submit` returns a correlation ID or 0 when the bounded in-flight queue is full. Translate
refusal into an explicit response (commonly 503). Drain replies from `tick` and match them to
request IDs. On `SERVER_STOPPING`, call `job_stop`; it finishes queued jobs and joins workers, so
bound the work or shutdown can wait.

Only pure Goose code can run in a thread. Calls that reach framework C (including SQLite, clock,
crypto, files and sockets) are main-thread-only. Jobs/results must be flat values, without slices,
builders or references. A worker abort is reported as a lost job, and that worker slot restarts.

The following is a complete small queue flow; the calculation is pure Goose, and a full example
with bounded result tracking, SSE, and expiry is in [examples/jobs](../../examples/jobs/server.goose).

```goose
import goose_web from "../goose-web";
import std;
import os;

struct Work { value: i64 }
struct Result { doubled: i64 }
struct Accepted { id: i64 }
var jobs: web::JobPool;
var control = default<web::ServerControl>();

fn double(work: Work) -> Result { return Result { doubled: work.value * 2 }; }
thread_fn worker(slot: i64) { web::job_worker<Work, Result>(slot, double); }
fn app(c: web::Ctx&) {
    c.routes() {
        c.post("/work/:value") {
            let value, ok = c.param_int("value");
            guard ok else { return; }
            let id = web::job_submit(jobs, Work { value: value });
            guard id > 0 else { c.fail(web::HTTP_SERVICE_UNAVAILABLE, "queue_full", "Retry later"); return; }
            c.status(web::HTTP_ACCEPTED).json(Accepted { id: id });
        };
    };
}
fn tick() { web::job_drain<Result>(jobs, worker) { reply => print(reply.id, ": ", reply.value.doubled) }; }
fn lifecycle(stage: i32, stats: web::ServerStats) {
    if stage == web::SERVER_STOPPING { web::job_stop<Work>(jobs); }
}
fn main() {
    jobs = web::job_pool(2, 8);
    web::job_start<Work, Result>(jobs, worker);
    var config = web::server_config();
    // The thread pool is started before serving; keep this sample single-process.
    config.workers = 1;
    config.handle_signals = true;
    let started = web::run_with(config, control, app, tick, lifecycle);
    if !started { abort("server failed"); }
}
```

The pool bounds queued plus running jobs until `tick` drains a reply. Start the thread pool in a
single-process server as shown; starting threads before a pre-fork worker server is unsafe. A `JOB_LOST` reply means a
worker aborted; `job_drain` receives both lost and successful replies. `job_stop` waits for queued
work, so long jobs delay shutdown. Detailed constraints: [Background jobs API](../api.md#background-jobs).
