# Goose Web — Async-first roadmap

**Status:** experimental pre-alpha. APIs and examples are prototypes until checked against a pinned Goose compiler revision.

## Architecture commitments

- **Async from the outset:** nonblocking sockets + readiness-based reactor, not one blocking thread per connection. Portable transport adapters may use poll/epoll/kqueue/IOCP; the initial POSIX proof of concept uses poll.
- **Native events:** a first-class typed event system for `on`, `once`, `off`, `emit`, `dispatch`, with payload arguments, listener IDs, bounded queues, explicit cancellation and errors.
- **Two execution modes:** synchronous dispatch for internal lifecycle hooks, and asynchronous queued delivery on the event loop. Preserve per-source FIFO ordering unless an explicit concurrent worker policy is selected.
- **Goose-first:** routing, validation, lifecycle and event semantics in Goose; small C shim only for missing native socket/event primitives.
- **Memory-safe contracts:** copy/move flat event payloads into owned bounded queues. Never capture a request-local slice across an asynchronous boundary.
- **Hackable and extensible:** compile-time handler wiring first, plugin/module composition and zero runtime reflection.
- **API first:** ergonomic routes with typed request/response bodies and opt-in OpenAPI later.

## M0 — foundation / async reactor and event semantics

- [x] Repo initialization, architecture, initial router and unsafe-to-deploy synchronous transport spike
- [x] Document async-first decision and native event architecture
- [x] Add initial typed event-envelope/queue sample and native nonblocking transport adapter draft
- [ ] Confirm current Goose compiler supports examples and package imports
- [ ] Record pinned compiler commit in compatibility matrix
- [ ] Replace the synchronous demo with an asynchronous reactor-backed HTTP example
- [ ] Validate C/Goose ABI and networking behavior on Linux
- [ ] Test event emission/dispatch/order/once/unsubscribe/overflow
- [ ] Implement graceful shutdown and cancellation

**Exit criteria:** a working nonblocking event-loop hello-world with integration tests, plus typed emit/subscribe/dispatch semantics; explicit limitations documented.

## M1 — HTTP/1.1 alpha (v0.1)

- [ ] Readiness-based connection state machine with bounded connection/request buffers
- [ ] Incremental HTTP parser and read/write state machine supporting partial reads/writes
- [ ] Strict content-length / transfer-encoding validation, safe timeouts and malformed input rejection
- [ ] Router with static, parametric and grouped paths
- [ ] JSON request/response, status/headers and method handling
- [ ] Middleware lifecycle via the event dispatcher and structured errors
- [ ] Bounded in-flight requests, backpressure, cancellation and graceful shutdown
- [ ] Fuzz tests, Linux/macOS CI and benchmarking

**Exit criteria:** a secure bounded HTTP/1.1 server under concurrent load without blocking client I/O.

## M2 — ergonomic APIs and native events (v0.2)

- [ ] Compile-time typed listeners with payload schemas, convenient `on/once/off/emit` API
- [ ] Listener priorities, wildcard/topic filters, `wait_for` and emission receipts
- [ ] Configurable queue policies: reject, drop-newest, drop-oldest, never silently unbounded
- [ ] Typed errors and correlation IDs, delivery metrics and exception policies
- [ ] Route and lifecycle hooks through the event bus
- [ ] Typed body/query/path validation, OpenAPI 3.1 generation, middleware/plugins
- [ ] Cross-thread event handoff with flat typed messages

## M3 — realtime and performance (v0.3)

- [ ] SSE and WebSocket transport with subscription backpressure
- [ ] Benchmarked worker execution model compatible with Goose isolated threads
- [ ] Production event-loop backend per OS, TLS adapter and HTTP/2 feasibility
- [ ] Event tracing and distributed observability adapters
- [ ] Streaming, request cancellation and fair scheduling
- [ ] DB, Redis and message-broker bridges as **optional packages**

## M4 — production and stable APIs (v1.0)

- [ ] API compatibility policy and extension specification
- [ ] Security review, OS portability and CI compatibility matrix
- [ ] Hardening and performance comparisons to Fastify, Axum and FastAPI
- [ ] Full documentation, sample apps, Docker deployment
- [ ] Stable versioning after adoption feedback

## Event subsystem semantics

A **subscription** is a compile-time handler association plus a runtime token/active bit; because Goose does not expose escaping closures or general runtime function pointers, arbitrary dynamically captured handler functions cannot be assumed. Event names and payload types should be declared in a typed schema; an event envelope owns its payload. The initial runtime can route by an enum tag through generated/direct code, then use per-event listener tokens for lifecycle control.

`emit` queues an event and returns a receipt or backpressure status. `dispatch` invokes eligible listeners at a controlled boundary. `emit_sync` dispatches immediately and documents reentrancy. Listener failures are isolated/reported by policy, not swallowed. One-time listeners deactivate *before* invocation to prevent recursive double delivery.

## Major risks

Goose's compile-time callable blocks, isolated workers, data-stack lifetimes, compiler changes and lack of native async/await call for **explicit state machines**, not a Tokio clone. No assertion of validated compilation or production performance until independently tested.
