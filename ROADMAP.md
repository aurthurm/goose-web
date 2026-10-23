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

## Milestone 2.5: application API

- [x] Application DSL: `c.routes()` with route blocks, `c.group` prefixes, path parameters, automatic 404 and 405 with `Allow`.
- [x] Reflective JSON codec: `json_encode` and strict `json_decode<T>` over `fields<T>`, with PATCH presence through `has<T>`.
- [x] Typed request bodies (`body<T>`, `body_result<T>`) and JSON responses (`c.json`, `c.json_list`) with 415, 400 and 422 handled.
- [x] Built-in middleware (`request_id`, `logger`, `cors`, `require_json`) and user middleware as `fn name<Next>(c)`.
- [x] Todo example rewritten onto the application API; `examples/hello` smoke test; unit contracts for routes, bodies and store.
- [x] Static file serving as middleware (`c.static_files`): GET/HEAD, index.html, content types, traversal and encoding refusals.
- [x] Cookies: `c.cookie` reads the Cookie header; `c.set_cookie` emits validated Set-Cookie lines (repeatable).
- [x] Typed query binding: `query<T>(c)` and `query_result<T>(c)` with strict keys and `invalid_query` errors.
- [x] Keep-alive connections: persistent HTTP/1.1 and opt-in HTTP/1.0, in-order pipelining, idle and per-connection limits.
- [x] Response bodies up to 1 MiB by default (16 MiB ceiling) in a growable, reused buffer (`max_response_bytes`); in-flight responses share a pool capped by `max_pool_bytes`, with 503 when it is full.
- Next: chunked/streaming bodies.
- [x] OpenAPI 3.1 generated from the routes block and struct reflection (`web::openapi`), with a `/docs` page.
- [x] Reflective SQLite layer (`db/`, `web::db`): CRUD from `fields<T>` with bound parameters, a query builder, transactions, migrations with `schema_version`, WAL file databases, example `examples/sqlite-todos`. Blocking calls on the reactor thread; worker offload is future work.
- [x] Compile-time HTML templates (`embed_file`, `html_template`, `render`, `check_template`): escaped and raw values, bool sections, `each` over struct arrays, comments, and `form<T>` for urlencoded bodies; example `examples/pages`.
- Next: typed configuration from environment variables.

## Milestone 3: protocol and platform coverage

- [x] Strict request profile, malformed-input/prefix regressions, and deterministic parser fuzz/property checks.
- [x] Pinned upstream compiler and Linux CI definition for GCC and Clang.
- Broader conformance and coverage-guided fuzzing before public deployment.
- [x] Keep-alive with explicit idle, per-request, and per-connection limits.
- Streaming and chunked encoding with explicit ownership/backpressure.
- Windows transport, then evaluate epoll/kqueue under measured load.
- TLS integration and deployment guidance.

## Milestone 4: asynchronous application work

- Typed worker jobs/completions without sharing borrowed request memory.
- Cooperative task states, cancellation, and timers integrated with readiness.
- Benchmarks covering slow clients, queue saturation, latency, and memory bounds.

Async network I/O is implemented now. Language-level async/await is not implied by
this roadmap: application suspension must fit the upstream compiler's memory model.
