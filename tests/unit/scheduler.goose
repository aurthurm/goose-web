// Import only the public package, just as an application does.
import goose_web from "../..";
import std;

// The *_at functions take the time explicitly, so these checks run on a fake clock.
const MS = 1000000;

// Records the ids a due call ran, in order, into a fixed buffer.
struct Ran { ids: i64[16], count: i64 }

fn note(ran: Ran&, id: i64) {
    ran.ids[ran.count] = id;
    ran.count += 1;
}

fn test_every_and_after_timing() {
    var sched = web::scheduler();
    var ran = Ran { ids: [0; 16], count: 0 };
    assert(web::every_at(sched, 1, 100, 0));
    assert(web::after_at(sched, 2, 50, 0));
    assert(web::next_due_ns(sched) == 50 * MS);
    // Nothing is due before its time.
    assert(web::due_at(sched, 49 * MS) { id => note(ran, id) } == 0);
    assert(ran.count == 0);
    // At 50 ms the one-shot runs and the periodic one, due at 100 ms, does not.
    assert(web::due_at(sched, 50 * MS) { id => note(ran, id) } == 1);
    assert(ran.count == 1 && ran.ids[0] == 2);
    assert(web::next_due_ns(sched) == 100 * MS);
    // The one-shot is gone: a later call does not repeat it.
    assert(web::due_at(sched, 60 * MS) { id => note(ran, id) } == 0);
}

fn test_catch_up_skips_missed_intervals() {
    var sched = web::scheduler();
    var ran = Ran { ids: [0; 16], count: 0 };
    assert(web::every_at(sched, 7, 100, 0));
    // The tick was late by 350 ms: the task runs once, and its next run is the first phase point after now.
    assert(web::due_at(sched, 450 * MS) { id => note(ran, id) } == 1);
    assert(ran.count == 1);
    assert(web::next_due_ns(sched) == 500 * MS);
    // The phase is kept: it runs at 500 ms, not at 450 ms plus an interval.
    assert(web::due_at(sched, 499 * MS) { id => note(ran, id) } == 0);
    assert(web::due_at(sched, 500 * MS) { id => note(ran, id) } == 1);
    assert(ran.count == 2);
    assert(web::next_due_ns(sched) == 600 * MS);
}

fn test_cancel_and_replace() {
    var sched = web::scheduler();
    var ran = Ran { ids: [0; 16], count: 0 };
    assert(web::every_at(sched, 3, 10, 0));
    assert(web::cancel(sched, 3));
    assert(!web::cancel(sched, 3));
    assert(!web::cancel(sched, 99));
    assert(web::due_at(sched, 1000 * MS) { id => note(ran, id) } == 0);
    assert(web::next_due_ns(sched) == 0);
    // Scheduling an id again replaces its timing rather than adding a second task.
    assert(web::every_at(sched, 4, 10, 0));
    assert(web::every_at(sched, 4, 30, 0));
    assert(web::due_at(sched, 10 * MS) { id => note(ran, id) } == 0);
    assert(web::due_at(sched, 30 * MS) { id => note(ran, id) } == 1);
    assert(ran.count == 1);
}

fn test_cancel_inside_block() {
    var sched = web::scheduler();
    var ran = Ran { ids: [0; 16], count: 0 };
    assert(web::after_at(sched, 5, 0, 0));
    assert(web::after_at(sched, 6, 0, 0));
    // The block cancels 6 while 5 runs: 6 does not run in the same call.
    let n = web::due_at(sched, 0) { id => { note(ran, id); web::cancel(sched, 6); } };
    assert(n == 1 && ran.ids[0] == 5);
    assert(web::next_due_ns(sched) == 0);
}

fn test_tasks_added_during_due_wait_for_next_call() {
    var sched = web::scheduler();
    var ran = Ran { ids: [0; 16], count: 0 };
    assert(web::after_at(sched, 8, 0, 0));
    let n = web::due_at(sched, 0) { id => { note(ran, id); web::after_at(sched, 9, 0, 0); } };
    assert(n == 1 && ran.count == 1);
    assert(web::due_at(sched, 0) { id => note(ran, id) } == 1);
    assert(ran.ids[1] == 9);
}

fn test_bounds() {
    var sched = web::scheduler();
    assert(!web::every_at(sched, 1, 0, 0));
    assert(!web::every_at(sched, 1, web::MAX_SCHEDULE_MS + 1, 0));
    assert(!web::after_at(sched, 1, -1, 0));
    for i in web::MAX_SCHEDULED_TASKS {
        assert(web::after_at(sched, 100 + i, 1, 0));
    }
    // The table is full: a new id is refused, an existing one is still replaced.
    assert(!web::after_at(sched, 1000, 1, 0));
    assert(web::every_at(sched, 100, 5, 0));
}

fn test_wake_hint() {
    var sched = web::scheduler();
    var control = default<web::ServerControl>();
    web::hint_wakeup(sched, control);
    assert(control.wake_at_ns == 0);
    assert(web::after_at(sched, 1, 20, 0));
    assert(web::every_at(sched, 2, 5, 0));
    web::hint_wakeup(sched, control);
    assert(control.wake_at_ns == 5 * MS);
}

fn main() {
    test_every_and_after_timing();
    test_catch_up_skips_missed_intervals();
    test_cancel_and_replace();
    test_cancel_inside_block();
    test_tasks_added_during_due_wait_for_next_call();
    test_bounds();
    test_wake_hint();
    print("scheduler unit tests passed\n");
}
