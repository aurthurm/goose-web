import src.constants.runtime;
import src.runtime.server;
import src.sys.process;
import std;
namespace web;

// Reactor-side scheduler: periodic and one-shot tasks, run from the tick. Nothing here starts a
// thread or waits; a task runs on the reactor thread, so it must return quickly (see the Background
// jobs section of docs/api.md for work that takes longer).
//
// Times come from the monotonic clock (clock_ns). The *_at functions take the time explicitly so
// tests can drive a fake clock; every, after and due read the real clock and call them.
//
// Catch-up policy: a periodic task that falls behind runs once when the tick next sees it due, and its
// next run is the first point of its phase (due + k * interval) that lies after now. Missed intervals
// are skipped, never replayed. A one-shot task runs once.
//
// Ids are caller-chosen. Scheduling an id that is already scheduled replaces that task.

const MAX_SCHEDULED_TASKS = 64;
// Durations in milliseconds are capped at one day, as the server's own timeouts are.
const MAX_SCHEDULE_MS = 86400000;

// A task slot. seq orders the slots by creation: a task created during due runs in a later call.
struct ScheduledTask { id: i64, active: bool, periodic: bool, interval_ns: i64, due_ns: i64, seq: i64 }
struct Scheduler { tasks: ScheduledTask[MAX_SCHEDULED_TASKS], next_seq: i64 }

fn scheduler() -> Scheduler {
    return Scheduler { tasks: [default<ScheduledTask>(); MAX_SCHEDULED_TASKS], next_seq: 1 };
}

// Finds the slot of id, or of a free slot when id is not scheduled. -1 when the table is full.
fn scheduled_slot(sched: Scheduler&, id: i64) -> i64 {
    var free: i64 = -1;
    for i in sched.tasks.len {
        if sched.tasks[i].active && sched.tasks[i].id == id { return i; }
        if !sched.tasks[i].active && free < 0 { free = i; }
    }
    return free;
}

// Shared by every and after. Returns false, changing nothing, for a bad duration or a full table.
fn schedule_task(sched: Scheduler&, id: i64, periodic: bool, interval_ms: i64, delay_ms: i64, now: i64) -> bool {
    if interval_ms < 1 || interval_ms > MAX_SCHEDULE_MS || delay_ms < 0 || delay_ms > MAX_SCHEDULE_MS { return false; }
    let slot = scheduled_slot(sched, id);
    if slot < 0 { return false; }
    let interval_ns = interval_ms * NANOSECONDS_PER_MILLISECOND;
    let due = if periodic { now + interval_ns } else { now + delay_ms * NANOSECONDS_PER_MILLISECOND };
    sched.tasks[slot] = ScheduledTask { id: id, active: true, periodic: periodic, interval_ns: interval_ns,
        due_ns: due, seq: sched.next_seq };
    sched.next_seq += 1;
    return true;
}

// Runs id every interval_ms, first after one interval. Returns false when the table is full.
fn every_at(sched: Scheduler&, id: i64, interval_ms: i64, now: i64) -> bool {
    return schedule_task(sched, id, true, interval_ms, 0, now);
}

// Runs id once, after delay_ms (0 means at the next tick).
fn after_at(sched: Scheduler&, id: i64, delay_ms: i64, now: i64) -> bool {
    return schedule_task(sched, id, false, 1, delay_ms, now);
}

// Removes id. False when it is not scheduled. A task cancelled in its own block does not run again.
fn cancel(sched: Scheduler&, id: i64) -> bool {
    let slot = scheduled_slot(sched, id);
    if slot < 0 || !sched.tasks[slot].active || sched.tasks[slot].id != id { return false; }
    sched.tasks[slot].active = false;
    return true;
}

fn every(sched: Scheduler&, id: i64, interval_ms: i64) -> bool { return every_at(sched, id, interval_ms, clock_ns()); }
fn after(sched: Scheduler&, id: i64, delay_ms: i64) -> bool { return after_at(sched, id, delay_ms, clock_ns()); }

// Earliest due time among scheduled tasks, or 0 when there are none.
fn next_due_ns(sched: Scheduler&) -> i64 {
    var next: i64 = 0;
    for i in sched.tasks.len {
        let t = sched.tasks[i];
        if t.active && (next == 0 || t.due_ns < next) { next = t.due_ns; }
    }
    return next;
}

// Runs each task due at now once, calling F(id) for it, and returns how many ran. Tasks run in table
// order within one call. Only tasks scheduled before the call are considered. Returns 0 without
// running anything when no task is due.
fn due_at<F>(sched: Scheduler&, now: i64) -> i64 {
    var ran: i64 = 0;
    let cutoff = sched.next_seq;
    for i in sched.tasks.len {
        if !sched.tasks[i].active || sched.tasks[i].seq >= cutoff || sched.tasks[i].due_ns > now { continue; }
        let id = sched.tasks[i].id;
        if sched.tasks[i].periodic {
            // Advance past now in whole intervals: missed runs are skipped.
            let interval = sched.tasks[i].interval_ns;
            let missed = (now - sched.tasks[i].due_ns) / interval;
            sched.tasks[i].due_ns += (missed + 1) * interval;
        } else {
            sched.tasks[i].active = false;
        }
        ran += 1;
        F(id);
    }
    return ran;
}

// Runs the due tasks with the real clock. Call it from the tick, with a block per id:
//   web::due(sched) { id => run_task(id) }
fn due<F>(sched: Scheduler&) -> i64 {
    return due_at(sched, clock_ns(), F);
}

// Asks the reactor to wake for the next due task instead of waiting out its poll interval. Call it
// from the tick after running due tasks; the hint is replaced on every call. Lateness is still bounded
// by poll_timeout_ms, because a task scheduled after this call (from a handler, say) is not seen
// until the next call.
fn hint_wakeup(sched: Scheduler&, control: ServerControl&) {
    control.wake_at_ns = next_due_ns(sched);
}
