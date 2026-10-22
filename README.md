# Goose Web

**Async-first, API-first web framework for the [Goose programming language](https://github.com/aardappel/goose).**

> Experimental pre-alpha. This is a new framework project, not an existing production HTTP server.

## Design

Goose Web aims for Fastify-like ergonomics, Axum-like composition and the Goose language's own memory model. Its runtime will use a **nonblocking native event loop** and a **first-class typed event system** (subscribe/listen, once, unsubscribe, emit, dispatch, payloads and bounded queued delivery).

The framework will be modular: request/response, HTTP router, JSON and lifecycle hooks in the core; authentication, docs, DBs, brokers and metrics as optional packages.

## What is actually here

- `web.goose`: initial stateless route match/status helpers (not yet compiler verified).
- `events.goose`: typed bounded FIFO event storage prototype (listener dispatch not yet implemented).
- `examples/hello.goose` and `native/posix_transport.c`: **legacy synchronous interoperability spike**, loopback only; not an async server or a production example.
- `ROADMAP.md`: detailed, prioritized development and acceptance milestones.
- `ARCHITECTURE.md`: async reactor and native event-management design.

See [ROADMAP.md](ROADMAP.md), [ARCHITECTURE.md](ARCHITECTURE.md) and [CONTRIBUTING.md](CONTRIBUTING.md). A build/test and a working async HTTP server are not yet verified.

## Event API direction

```text
app.events.on(Event.Ready) { event => ... }
app.events.once(Event.UserCreated) { event => ... }
app.events.emit(Event.UserCreated { id: 42 })
app.events.dispatch(64)
```

This is **design-target pseudocode**, not guaranteed to compile in Goose. Goose currently restricts escaping closures and function pointer storage; therefore the implementation will use static/compile-time dispatch and runtime subscription tokens.
