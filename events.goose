// Experimental typed event queue. Async delivery means queued, explicitly
// pumped delivery; this is not a compiler-level async/await implementation.
// Event payloads are flat/owned values so they can later cross worker queues.
import std;

enum Event {
    Ready,
    UserCreated { id: i64, tenant_id: i64 },
    RequestFinished { request_id: i64, status: i32 },
    Failed { code: i32 },
}

// Fixed-capacity queue: explicit overflow (false), never silently unbounded.
// Names are temporary until the typed subscription API stabilizes.
struct EventQueue { pending: Event[..128] }

fn event_queue() -> EventQueue { EventQueue { pending: [] } }

// Enqueue, preserving FIFO order. Caller handles overflow/backpressure.
fn emit(q: EventQueue&, event: Event) -> bool {
    if q.pending.len >= 128 { return false; }
    q.pending.push(event);
    return true;
}

// Compile-time callback block. This is intentionally NOT an escaping closure.
// Direct handler dispatch can match Event variants and consult subscription
// flags/tokens owned by the calling application.
fn dispatch<F>(q: EventQueue&, budget: i64) -> i64 {
    var count: i64 = 0;
    while q.pending.len > 0 && count < budget {
        let event = remove_at(q.pending, 0);
        F(event);
        count++;
    }
    return count;
}

fn pending_events(q: EventQueue&) -> i64 { q.pending.len; }
