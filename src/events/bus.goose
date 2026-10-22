import std;
namespace web;

// Payloads must be fixed-size values; buffers with explicit capacity work too.
struct Event<T> { topic: i32, args: T }
struct Subscription { id: i64, topic: i32, once: bool, active: bool }
struct EventBus<T> {
    listeners: Subscription[64],
    queue: Event<T>[256],
    head: i64, count: i64, next_id: i64, draining: bool
}

fn event_bus<T>() -> EventBus<T> {
    return EventBus<T> {
        listeners: [default<Subscription>(); 64],
        queue: [default<Event<T>>(); 256], head: 0, count: 0, next_id: 1, draining: false
    };
}

// Zero means the subscription table is full. IDs are never reused.
fn subscribe<T>(bus: EventBus<T>&, topic: i32, once: bool = false) -> i64 {
    for i in bus.listeners.len {
        if !bus.listeners[i].active {
            let id = bus.next_id;
            bus.next_id += 1;
            bus.listeners[i] = Subscription { id, topic, once, true };
            return id;
        }
    }
    return 0;
}

fn unsubscribe<T>(bus: EventBus<T>&, id: i64) -> bool {
    for i in bus.listeners.len {
        if bus.listeners[i].active && bus.listeners[i].id == id {
            bus.listeners[i].active = false;
            return true;
        }
    }
    return false;
}

// Bounded FIFO: false is explicit backpressure, never a silent drop.
fn dispatch<T>(bus: EventBus<T>&, topic: i32, args: T) -> bool {
    if bus.count == bus.queue.len { return false; }
    let tail = (bus.head + bus.count) % bus.queue.len;
    bus.queue[tail] = Event<T> { topic, args };
    bus.count += 1;
    return true;
}

// F(subscription_id, event). New events wait for the next drain call.
// Listeners present at an event's start run in subscription order; removals
// take effect immediately. Unsubscribe a once-listener before invoking it.
fn drain<T, F>(bus: EventBus<T>&) -> i64 {
    if bus.draining { return 0; }
    bus.draining = true;
    let batch = bus.count;
    for n in batch {
        let event = bus.queue[bus.head];
        bus.head = (bus.head + 1) % bus.queue.len;
        bus.count -= 1;
        let cutoff = bus.next_id;
        var previous: i64 = 0;
        loop {
            var index: i64 = -1;
            var next = cutoff;
            for i in bus.listeners.len {
                let s = bus.listeners[i];
                if s.active && s.topic == event.topic && s.id > previous && s.id < next {
                    index = i;
                    next = s.id;
                }
            }
            if index < 0 { break; }
            previous = next;
            if bus.listeners[index].once { bus.listeners[index].active = false; }
            F(next, event);
        }
    }
    bus.draining = false;
    return batch;
}
