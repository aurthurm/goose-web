# Native event management specification

Events are **part of the framework core**, rather than an optional plugin.

## Core operation

- `on(type, handler)`: register a repeatable typed listener.
- `once(type, handler)`: register one-time listener; deactivate before callback invocation.
- `off(subscription_token)`: deactivate; idempotent, safe during a dispatch pass.
- `emit(payload)`: enqueue an owned typed payload; return an explicit success/backpressure status.
- `emit_sync(payload)`: immediate delivery with documented reentrancy semantics.
- `dispatch(max_events)`: drain up to a bounded batch without starving sockets or timers.
- `wait_for(type, timeout)`: future phase, explicit timer/cancellation semantics.
- `listeners(type)`: introspection and optional per-topic metrics.

The current `events.goose` implements only **bounded FIFO typed event storage and compile-time dispatch**; on/once/off are design targets, not implemented yet.

## Handler model and Goose constraints

Goose callable blocks are compile-time entities rather than first-class escaping function pointers. To support named subscribers, use **statically generated handler dispatch** plus runtime listener tokens and active flags; never promise Python/Node-style runtime closures. Each event variant carries its argument fields. No borrowed references or request-buffer slices may enter an asynchronous queue.

## Queue and delivery guarantees

- Local queue: FIFO; best effort, at-most-once callback attempt, bounded capacity.
- On overflow: return `false` / `QueueFull` (configurable policy later). No silent discarding.
- `dispatch(budget)` always yields after a bounded number of deliveries.
- Cross-thread delivery: use Goose's typed flat queues and explicit ownership; no shared mutable listener maps.
- Exception policies: log/report/stop per listener; do not silently swallow failures.
- Persisted and distributed event guarantees are separate extensions; no misleading exactly-once claim.

## Planned typed user experience (PSEUDOCODE)

```text
app.on(Event.UserCreated) { e => audit(e.id, e.tenant_id) }
app.once(Event.Ready) { _ => announce() }
let sub = app.subscribe(Event.RequestFinished, on_request_finished)
app.off(sub)
let accepted = app.emit(Event.UserCreated { id: 42, tenant_id: 7 })
app.dispatch(64)
```

## Integration

Transport emits `ConnectionAccepted`, `RequestReceived`, `RequestFinished`, `ConnectionClosed`. Middleware and plugins can subscribe at compile time. Application events are namespaced and opt-in. HTTP request completion should not be blocked by arbitrary user-event handlers on the reactor thread.
