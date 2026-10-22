# Roadmap

## Milestone 1: working asynchronous foundation

- [x] Goose package with a small POSIX transport shim.
- [x] Nonblocking accept/read/write, poll readiness, partial writes, bounded client slots.
- [x] HTTP/1.1 parsing and response framing with explicit limits and deadlines.
- [x] Typed queued events: subscribe, unsubscribe, once, arguments, backpressure.
- [x] Runnable health/echo example and real-socket concurrency tests.

## Milestone 2: application composition

- [x] Bounded route composition with compile-time handlers, method matching, path parameters, query helpers.
- [x] Middleware composition and consistent application error responses.
- [x] Validated runtime configuration for limits, bind address, and deadlines.
- [x] Graceful shutdown, lifecycle callbacks, connection counters, and observable event queue state.
- [x] Package example with multiple event handlers and domain payloads.
- [x] Responsibility-based source folders and separate unit/native/integration test layers.

## Milestone 3: protocol and platform coverage

- HTTP parser conformance/fuzz testing before expanding exposure.
- Streaming, keep-alive, and chunked encoding with explicit ownership/backpressure.
- Windows transport, then evaluate epoll/kqueue under measured load.
- TLS integration and deployment guidance.

## Milestone 4: asynchronous application work

- Typed worker jobs/completions without sharing borrowed request memory.
- Cooperative task states, cancellation, and timers integrated with readiness.
- Benchmarks covering slow clients, queue saturation, latency, and memory bounds.

Async network I/O is implemented now. Language-level async/await is not implied by
this roadmap: application suspension must fit the upstream compiler's memory model.
