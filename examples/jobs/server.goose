import goose_web from "../..";
import std;
import os;

// Background jobs. POST /primes?limit=N queues a prime count on a worker thread and answers 202 with a
// job id. GET /jobs/:id reports the job, and GET /events streams a "done" event when each job finishes.
// A scheduler task drops finished jobs older than RESULT_TTL_NS every CLEANUP_MS.
//   build/jobs --port 8080

// Jobs in flight (queued or running, not yet drained). A request beyond this is answered 503.
const WORKERS = 2;
const QUEUE_LIMIT = 4;
const PRIME_LIMIT_MAX = 2000000;
// Tracked jobs (queued, or finished and not yet cleaned up). Full table: 503.
const TRACKED_JOBS = 64;
const JOBS_CHANNEL = 2;
const CLEANUP_TASK = 1;
const CLEANUP_MS = 30000;
const RESULT_TTL_NS = 60000000000;
const TRACK_QUEUED = 1;
const TRACK_DONE = 2;
const TRACK_FAILED = 3;

struct PrimeJob { limit: i64 }
struct PrimeResult { count: i64, largest: i64 }
struct PrimeQuery { limit: i64 = 0 }
struct JobAccepted { id: i64, status: u8[..8] }
struct JobView { id: i64, status: u8[..8], count: i64, largest: i64 }

// One job from accepted to cleanup. used = false marks a free slot.
struct Tracked { id: i64, status: i32, count: i64, largest: i64, finished_ns: i64, used: bool }

var control = default<web::ServerControl>();
var sched = web::scheduler();
var jobs: web::JobPool;
var tracked: Tracked[TRACKED_JOBS] = [default<Tracked>(); TRACKED_JOBS];

// Pure Goose, so it may run on a worker thread: a sieve of Eratosthenes up to the limit.
fn count_primes(job: PrimeJob) -> PrimeResult {
    var composite: u8[>..] = [];
    composite.resize(job.limit + 1, 0);
    var count: i64 = 0;
    var largest: i64 = 0;
    for i in job.limit - 1 {
        let n = i + 2;
        if composite[n] != 0 { continue; }
        count += 1;
        largest = n;
        var m = n * n;
        while m <= job.limit {
            composite[m] = 1;
            m += n;
        }
    }
    return PrimeResult { count: count, largest: largest };
}

// The worker thread: the framework runs jobs until the pool stops. The slot is its index in the pool.
thread_fn prime_worker(slot: i64) {
    web::job_worker<PrimeJob, PrimeResult>(slot, count_primes);
}

fn track_slot() -> i64 {
    for i in TRACKED_JOBS {
        if !tracked[i].used { return i; }
    }
    return -1;
}

fn find_tracked(id: i64) -> i64 {
    for i in TRACKED_JOBS {
        if tracked[i].used && tracked[i].id == id { return i; }
    }
    return -1;
}

fn job_view(t: Tracked) -> JobView {
    var v = JobView { id: t.id, status: "queued", count: 0, largest: 0 };
    if t.status == TRACK_DONE {
        v.status = "done";
        v.count = t.count;
        v.largest = t.largest;
    }
    if t.status == TRACK_FAILED { v.status = "failed"; }
    return v;
}

// Runs on the reactor, from the tick: records the reply and announces it on the event stream.
fn finish(r: web::JobReply<PrimeResult>) {
    let at = find_tracked(r.id);
    if at < 0 { return; }
    tracked[at].finished_ns = web::clock_ns();
    if r.kind == web::JOB_DONE {
        tracked[at].status = TRACK_DONE;
        tracked[at].count = r.value.count;
        tracked[at].largest = r.value.largest;
    } else {
        tracked[at].status = TRACK_FAILED;
    }
    var text: u8[>..] = [];
    web::json_encode(text, job_view(tracked[at]));
    web::sse_publish(control, JOBS_CHANNEL, "done", text[..]);
}

// Scheduler task: drops finished jobs once they are older than RESULT_TTL_NS. Queued jobs are kept.
fn cleanup() {
    let now = web::clock_ns();
    for i in TRACKED_JOBS {
        if tracked[i].used && tracked[i].status != TRACK_QUEUED && now - tracked[i].finished_ns >= RESULT_TTL_NS {
            tracked[i].used = false;
        }
    }
}

fn run_task(id: i64) {
    if id == CLEANUP_TASK { cleanup(); }
}

// Tick: hand finished results to finish, run the due scheduler tasks, and ask the reactor to wake for
// the next one. The drain runs after the stop too, so results finished during shutdown are announced.
fn tick() {
    web::job_drain<PrimeResult>(jobs, prime_worker) { r => finish(r) };
    web::due(sched) { id => run_task(id) };
    web::hint_wakeup(sched, control);
}

// SERVER_STOPPING: no new jobs; the workers finish what is queued, and the server waits for them.
fn lifecycle(stage: i32, stats: web::ServerStats) {
    if stage == web::SERVER_STOPPING { web::job_stop<PrimeJob>(jobs); }
}

fn app(c: web::Ctx&) {
    c.logger() {
        c.routes() {
            c.post("/primes") {
                let q, ok = web::query<PrimeQuery>(c);
                guard ok else { return; }
                guard q.limit >= 2 && q.limit <= PRIME_LIMIT_MAX else {
                    c.fail(web::HTTP_UNPROCESSABLE_CONTENT, "bad_limit", "limit must be between 2 and 2000000");
                    return;
                }
                let slot = track_slot();
                guard slot >= 0 else {
                    c.fail(web::HTTP_SERVICE_UNAVAILABLE, "tracking_full", "Too many jobs are tracked; retry later");
                    return;
                }
                let id = web::job_submit(jobs, PrimeJob { limit: q.limit });
                guard id > 0 else {
                    c.fail(web::HTTP_SERVICE_UNAVAILABLE, "queue_full", "The job queue is full; retry later");
                    return;
                }
                tracked[slot] = Tracked { id: id, status: TRACK_QUEUED, count: 0, largest: 0, finished_ns: 0, used: true };
                c.status(web::HTTP_ACCEPTED).json(JobAccepted { id: id, status: "queued" });
            };
            c.get("/jobs/:id") {
                let id, ok = c.param_int("id");
                guard ok else {
                    c.fail(web::HTTP_NOT_FOUND, "not_found", "No such job");
                    return;
                }
                let at = find_tracked(id);
                guard at >= 0 else {
                    c.fail(web::HTTP_NOT_FOUND, "not_found", "No such job");
                    return;
                }
                c.json(job_view(tracked[at]));
            };
            c.get("/events") { c.sse(JOBS_CHANNEL); };
        };
    };
}

fn main() {
    let config, ok, error = web::config_from_args(args());
    if !ok { abort(error); }
    var settings = config;
    settings.handle_signals = true;
    jobs = web::job_pool(WORKERS, QUEUE_LIMIT);
    web::job_start<PrimeJob, PrimeResult>(jobs, prime_worker);
    assert(web::every(sched, CLEANUP_TASK, CLEANUP_MS));
    print("Jobs server on port ", settings.port, ": POST /primes?limit=N, GET /jobs/:id, GET /events");
    let started = web::run_with(settings, control, app, tick, lifecycle);
    if !started { abort("server failed"); }
}
