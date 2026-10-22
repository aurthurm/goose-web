# Goose Web architecture — async-first

## Runtime

```text
nonblocking socket readiness
           |
           v
     reactor / event loop  -------> bounded timer/cancellation queue
           |
           v
   connection state machines
           |
           v
     HTTP parser / router
           |
           v
     Goose request handlers
           |
           v
    write queue / backpressure

  Event subsystem (cross-cutting)
  on / once / off / emit / dispatch
       | typed envelopes
       v
  bounded FIFO + static handler dispatch
```

**An event loop is not automatically `async/await`.** Goose lacks Tokio-style futures; use explicitly polled state machines, yielding bounded work and never blocking the reactor on DB calls or sleeps. Blocking tasks will eventually be handed to isolated worker threads using flat typed queue messages.

## Event core

Events are native framework primitives, not a web plugin. Define a typed event catalog (enum variants with payloads), routing code generated/static by event type, listener bookkeeping and a bounded owned-payload queue. The initial `events.goose` provides a small FIFO queue, demonstrating the ownership/dispatch basis; full dynamic subscription and delivery are roadmap items. Arbitrary callback values cannot be stored as runtime listener pointers under Goose's current type system.

**Planned public API (design only):**

```text
app.events.on(Event.UserCreated) { event => ... }
app.events.once(Event.Ready) { event => ... }
let token = app.events.subscribe(Event.UserCreated, handler)
app.events.off(token)
app.events.emit(Event.UserCreated { id: 42, name: "Ana" })
app.events.dispatch(64) // bounded batch; never block transport forever
```

Payloads must be owned/flat when sent across worker boundaries. Cancellation and once semantics must be deterministic. A bounded queue has explicit overflow behavior. Avoid exposing borrowed request/body data after the request scope.

## Bootstrap warning

The initial synchronous `examples/hello.goose` and POSIX shim predate the async-first decision and are retained only as a transport interoperability spike. **They are not the runtime architecture.** No part of the prototype is production safe. The async reactor and incremental HTTP parser must replace it before the first alpha.

## Security and performance

Backpressure, timeout handling, partial I/O, slowloris defenses, protocol ambiguity detection, cancellations and proper lifecycle closure precede public deployment. Compare native event-loop designs with reproducible connection-count, throughput, CPU, RSS and tail-latency measurements. TLS can initially terminate at a reverse proxy.
