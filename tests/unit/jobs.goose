// Import only the public package, just as an application does.
import goose_web from "../..";
import std;
import os;

// Job helpers on real threads: submission limits, replies, a contained abort with restart, shutdown.
struct Job { n: i64 }
struct Result { n: i64, value: i64 }

// Tallies what the drain reports. Each reply is either DONE (value set) or LOST (value zero).
struct Tally { done: i64, lost: i64, sum: i64, last_lost: i64 }
var tally = Tally { done: 0, lost: 0, sum: 0, last_lost: 0 };

// Pure Goose work. Job 99 aborts its worker, which the pool must contain and restart.
fn square(job: Job) -> Result {
    assert(job.n != 99);
    return Result { n: job.n, value: job.n * job.n };
}

thread_fn job_thread(slot: i64) {
    web::job_worker<Job, Result>(slot, square);
}

fn record(r: web::JobReply<Result>) {
    if r.kind == web::JOB_DONE {
        tally.done += 1;
        tally.sum += r.value.value;
    } else if r.kind == web::JOB_LOST {
        tally.lost += 1;
        tally.last_lost = r.id;
    }
}

// Drains until the pool has no job in flight, sleeping briefly between passes.
fn drain_all(pool: web::JobPool&) {
    var passes: i64 = 0;
    while web::job_in_flight(pool) > 0 {
        web::job_drain<Result>(pool, job_thread) { r => record(r) };
        sleep_ms(1);
        passes += 1;
        assert(passes < 20000);
    }
    web::job_drain<Result>(pool, job_thread) { r => record(r) };
}

fn test_refused_before_start() {
    var pool = web::job_pool(2, 4);
    assert(web::job_submit(pool, Job { n: 1 }) == 0);
    assert(web::job_in_flight(pool) == 0);
}

fn test_limits_and_replies() {
    var pool = web::job_pool(2, 4);
    web::job_start<Job, Result>(pool, job_thread);
    let a = web::job_submit(pool, Job { n: 2 });
    let b = web::job_submit(pool, Job { n: 3 });
    let c = web::job_submit(pool, Job { n: 4 });
    let d = web::job_submit(pool, Job { n: 5 });
    assert(a == 1 && b == 2 && c == 3 && d == 4);
    // Four in flight is the limit: the fifth is refused and changes nothing.
    assert(web::job_submit(pool, Job { n: 6 }) == 0);
    assert(web::job_in_flight(pool) == 4);
    drain_all(pool);
    assert(tally.done == 4);
    assert(tally.sum == 4 + 9 + 16 + 25);
    assert(web::job_in_flight(pool) == 0);
    // The slots are free again.
    assert(web::job_submit(pool, Job { n: 7 }) == 5);
    drain_all(pool);
    assert(tally.done == 5 && tally.sum == 54 + 49);
    assert(web::job_restarts(pool) == 0);
    assert(web::job_stop<Job>(pool));
}

fn test_abort_is_lost_and_restarted() {
    var pool = web::job_pool(1, 4);
    web::job_start<Job, Result>(pool, job_thread);
    let bad = web::job_submit(pool, Job { n: 99 });
    assert(bad > 0);
    drain_all(pool);
    assert(tally.lost == 1 && tally.last_lost == bad);
    assert(web::job_restarts(pool) == 1);
    // The restarted worker serves the next job.
    let good = web::job_submit(pool, Job { n: 8 });
    assert(good > 0);
    drain_all(pool);
    assert(tally.done == 6 && tally.sum == 54 + 49 + 64);
    assert(web::job_in_flight(pool) == 0);
    assert(web::job_stop<Job>(pool));
}

fn test_shutdown_joins() {
    var pool = web::job_pool(2, 8);
    web::job_start<Job, Result>(pool, job_thread);
    assert(web::job_submit(pool, Job { n: 10 }) > 0);
    assert(web::job_submit(pool, Job { n: 11 }) > 0);
    assert(web::job_stop<Job>(pool));
    assert(!web::job_stop<Job>(pool));
    assert(web::job_submit(pool, Job { n: 12 }) == 0);
    // The queued jobs ran before the stop, and their replies wait for a final drain.
    web::job_drain<Result>(pool, job_thread) { r => record(r) };
    assert(tally.done == 8 && tally.sum == 54 + 49 + 64 + 100 + 121);
}

fn main() {
    test_refused_before_start();
    test_limits_and_replies();
    test_abort_is_lost_and_restarted();
    test_shutdown_joins();
    print("job unit tests passed\n");
}
