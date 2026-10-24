import std;
namespace web;

// Background job pool: CPU-bound or blocking pure-Goose work on Goose threads, so the reactor keeps
// serving. A job runs on a worker thread and must not call the framework's C code (sockets, the
// clock, SQLite, crypto, files): goose_web.build declares main_thread_only, so such a thread_fn does
// not compile. Results come back through typed queues and are handled on the reactor, in the tick.
// See the Background jobs section of docs/api.md.
//
// Shape of the program (the thread_fn names belong to the application):
//   thread_fn render_worker(slot: i64) { web::job_worker<Job, Result>(slot, render); }
//   var jobs = web::job_pool(2, 16);                       // workers, queue limit (in flight)
//   web::job_start<Job, Result>(jobs, render_worker);      // spawn the workers
//   let id = web::job_submit(jobs, Job { ... });           // handler: 0 means refused (answer 503)
//   web::job_drain<Result>(jobs, render_worker) { r => ... };  // tick: DONE and LOST replies
//   web::job_stop<Job>(jobs);                              // on SERVER_STOPPING: stop and join
//
// Bounds: at most queue_limit jobs are in flight (queued or running, until drained). Workers are
// MAX_JOB_WORKERS at most. A worker that aborts is contained: its job is reported as LOST and the
// slot is started again. Each slot has a watcher thread that waits for the worker and reports its
// abort through a queue; the watchers do no other work.

const MAX_JOB_WORKERS = 16;
// Reply kinds. STARTED is consumed by the drain; the block sees DONE and LOST only.
const JOB_STARTED = 1;
const JOB_DONE = 2;
const JOB_LOST = 3;
// Bound on abort notices (a slot has at most one live worker, so this is ample for the pool).
const JOB_DOWN_LIMIT = 4 * MAX_JOB_WORKERS;

// Messages on the typed queues. All fields are flat, so each crosses threads as one copy.
struct JobEnvelope<J> { id: i64, stop: bool, body: J }
struct JobReply<R> { id: i64, slot: i64, kind: i32, value: R }
struct JobWorkerDown { tag: i64, slot: i64 }

// The bookkeeping of one pool. Non-generic: the job and result types appear only in the calls.
// running[slot] is the id the slot started and has not finished (0 when idle); a worker that
// aborts while it is set loses that job. Each drain gets its own pool tag, so an abort notice
// carries the pool that owns it.
struct JobPool {
    tag: i64, workers: i64, queue_limit: i64, next_id: i64, in_flight: i64,
    worker_ids: i64[MAX_JOB_WORKERS], watcher_ids: i64[MAX_JOB_WORKERS], running: i64[MAX_JOB_WORKERS],
    restarts: i64, started: bool, stopped: bool
}

var job_pool_tags: i64 = 0;
// Pools started and not yet stopped in this program. Queues are per job type, so two pools with the
// same types would share one job queue: a program runs one pool at a time.
var job_pools_running: i64 = 0;

// A pool of `workers` threads that holds at most queue_limit jobs in flight. Nothing starts until job_start.
fn job_pool(workers: i64, queue_limit: i64) -> JobPool {
    assert(workers >= 1 && workers <= MAX_JOB_WORKERS);
    assert(queue_limit >= 1);
    job_pool_tags += 1;
    return JobPool { tag: job_pool_tags, workers: workers, queue_limit: queue_limit, next_id: 1, in_flight: 0,
        worker_ids: [0; MAX_JOB_WORKERS], watcher_ids: [0; MAX_JOB_WORKERS], running: [0; MAX_JOB_WORKERS],
        restarts: 0, started: false, stopped: false };
}

// Waits for one contained worker. A worker that aborts sends its slot to the queue; a worker that
// returns, as job_stop makes it, sends nothing. Thread programs do not share state, so the abort
// message is printed here, where the watcher took it.
thread_fn job_watch(tag: i64, slot: i64, id: i64) {
    var why: u8[>..] = [];
    if !thread_wait(id, why) {
        print("web: job worker ", slot, " aborted: ", why);
        qput(JobWorkerDown { tag: tag, slot: slot });
    }
}

// Starts a contained worker in slot and its watcher. W is the application's thread_fn taking the slot.
fn job_spawn<W>(pool: JobPool&, slot: i64) {
    // W is the application's worker: a function value passed as the trailing argument.
    let id = thread_spawn_contained(W, slot);
    pool.worker_ids[slot] = id;
    pool.watcher_ids[slot] = thread_spawn(job_watch, pool.tag, slot, id);
}

// Spawns the workers. J is the job type, R the result type; W the application's thread_fn.
// Set the queue limits for those types here, so one pool per job/result pair per program.
fn job_start<J, R, W>(pool: JobPool&) {
    assert(!pool.started);
    assert(job_pools_running == 0);
    pool.started = true;
    job_pools_running += 1;
    // Stop messages fit beside queued jobs: at most queue_limit jobs are in flight.
    qlimit<JobEnvelope<J>>(pool.queue_limit + pool.workers);
    // Each job puts at most two replies (STARTED, DONE) before the drain takes them.
    qlimit<JobReply<R>>(2 * pool.queue_limit + MAX_JOB_WORKERS);
    qlimit<JobWorkerDown>(JOB_DOWN_LIMIT);
    // Replies left by an earlier pool that was stopped without a final drain are discarded.
    for n in 2 * pool.queue_limit + MAX_JOB_WORKERS {
        let stale, got = qpoll<JobReply<R>>();
        if !got { break; }
    }
    for slot in pool.workers { job_spawn(pool, slot, W); }
}

// The body of a worker thread: take jobs until a stop message. F maps a job to its result. Runs in the
// worker, so F and everything it calls must be pure Goose. Declare the thread_fn in the application:
//   thread_fn render_worker(slot: i64) { web::job_worker<Job, Result>(slot, render); }
fn job_worker<J, R, F>(slot: i64) {
    loop {
        let envelope = qget<JobEnvelope<J>>();
        if envelope.stop { break; }
        let started = JobReply<R> { id: envelope.id, slot: slot, kind: JOB_STARTED, value: default<R>() };
        assert(qput(started));
        let value = F(envelope.body);
        let done = JobReply<R> { id: envelope.id, slot: slot, kind: JOB_DONE, value: value };
        assert(qput(done));
    }
}

// Queues body for a worker and returns its correlation id (at least 1), or 0 when refused: the pool is
// not started or stopping, queue_limit jobs are in flight, or the queue refused it. A refusal changes
// nothing; answer the request with 503.
fn job_submit<J>(pool: JobPool&, body: J) -> i64 {
    if !pool.started || pool.stopped || pool.in_flight >= pool.queue_limit { return 0; }
    let id = pool.next_id;
    if !qput(JobEnvelope<J> { id: id, stop: false, body: body }) { return 0; }
    pool.next_id += 1;
    pool.in_flight += 1;
    return id;
}

// Jobs queued or running, not yet drained.
fn job_in_flight(pool: JobPool&) -> i64 { return pool.in_flight; }

// Worker restarts since the pool started (aborted workers replaced).
fn job_restarts(pool: JobPool&) -> i64 { return pool.restarts; }

// Calls F with each DONE and each LOST reply (LOST carries the zero value), and returns how many. Call it
// from the tick. It reads abort notices first: a worker's STARTED reply was queued before its abort, so
// the reply drain sees it, and the lost job is known. Each lost slot is started again with W, the
// application's worker thread_fn, unless job_stop has run.
fn job_drain<R, W, F>(pool: JobPool&) -> i64 {
    var dead: i64[MAX_JOB_WORKERS] = [0; MAX_JOB_WORKERS];
    var dead_count: i64 = 0;
    // Notices of other pools go back on the queue. Bounded: a pass over the queue is at most this many.
    for attempt in JOB_DOWN_LIMIT {
        let down, got = qpoll<JobWorkerDown>();
        if !got { break; }
        if down.tag != pool.tag {
            qput(down);
            continue;
        }
        if dead_count < MAX_JOB_WORKERS {
            dead[dead_count] = down.slot;
            dead_count += 1;
        }
    }
    var handled: i64 = 0;
    for attempt in 2 * pool.queue_limit + MAX_JOB_WORKERS {
        let reply, got = qpoll<JobReply<R>>();
        if !got { break; }
        if reply.kind == JOB_STARTED {
            pool.running[reply.slot] = reply.id;
        } else if reply.kind == JOB_DONE {
            pool.running[reply.slot] = 0;
            pool.in_flight -= 1;
            handled += 1;
            F(reply);
        }
    }
    for d in dead_count {
        let slot = dead[d];
        let lost = pool.running[slot];
        pool.running[slot] = 0;
        if lost != 0 {
            pool.in_flight -= 1;
            handled += 1;
            F(JobReply<R> { id: lost, slot: slot, kind: JOB_LOST, value: default<R>() });
        }
        if !pool.stopped {
            job_spawn(pool, slot, W);
            pool.restarts += 1;
        }
    }
    return handled;
}

// Stops the workers and waits for them. Queued jobs run first: stop messages follow them. A job that is
// running is waited for, so a long job delays shutdown; keep jobs short or bounded. Replies that are
// still queued stay there for a final job_drain. Returns false if the pool was never started or is
// already stopped.
fn job_stop<J>(pool: JobPool&) -> bool {
    if !pool.started || pool.stopped { return false; }
    pool.stopped = true;
    for slot in pool.workers {
        var stop = JobEnvelope<J> { id: 0, stop: true, body: default<J>() };
        assert(qput(stop));
    }
    for slot in pool.workers {
        thread_wait(pool.worker_ids[slot]);
        thread_wait(pool.watcher_ids[slot]);
    }
    // Jobs that no live worker took (every worker aborted) and extra stop messages are discarded.
    for n in pool.queue_limit + pool.workers {
        let left, got = qpoll<JobEnvelope<J>>();
        if !got { break; }
    }
    job_pools_running -= 1;
    return true;
}
