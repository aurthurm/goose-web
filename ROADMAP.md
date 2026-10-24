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
- [x] Native HMAC-SHA256, SHA-256, CSPRNG and base64url in the POSIX shim (FIPS and RFC 4231 vectors), with signed cookie sessions (`session`) and double-submit CSRF protection (`csrf`).
- Next: key rotation with key ids, server-side session revocation, and a `Secure` option for the CSRF cookie.
- [x] Typed query binding: `query<T>(c)` and `query_result<T>(c)` with strict keys and `invalid_query` errors.
- [x] Keep-alive connections: persistent HTTP/1.1 and opt-in HTTP/1.0, in-order pipelining, idle and per-connection limits.
- [x] Response bodies up to 1 MiB by default (16 MiB ceiling) in a growable, reused buffer (`max_response_bytes`); in-flight responses share a pool capped by `max_pool_bytes`, with 503 when it is full.
- [x] Server-sent events: `c.sse`, `web::sse_publish`, chunked framing, heartbeats, slow-consumer drops, shutdown close events.
- Next: general chunked/streaming bodies beyond server-sent events.
- [x] OpenAPI 3.1 generated from the routes block and struct reflection (`web::openapi`), with a `/docs` page.
- [x] Field names and skipping: `web::json_key` (JSON name, as V's `@[json: name]`) and `web::json_skip` (`@[skip]`) for encode, decode, `query<T>`, and OpenAPI; `check_json_keys<T>()` for duplicate names.
- [x] Reflective SQLite layer (`db/`, `web::db`): CRUD from `fields<T>` with bound parameters, a query builder, transactions, migrations with `schema_version`, WAL file databases, example `examples/sqlite-todos`. Blocking calls on the reactor thread; worker offload is future work.
- [x] SQLite example documented and renamed (`done` on the wire for `completed`) with its OpenAPI document checked end to end.
- [x] Compile-time HTML templates (`embed_file`, `html_template`, `render`, `check_template`): escaped and raw values, bool sections, `each` over struct arrays, comments, and `form<T>` for urlencoded bodies; example `examples/pages`.
- [x] Template composition: shared layouts with named blocks (`{{$name}}`, `{{> content}}`), a partials registry (`add_template`, `{{> name}}`) with cycle and depth checks, `check_template` over page, layout and partials, `each` `else` and `@index`/`@first`/`@last`, dotted names into registered struct fields, and flash messages (`c.flash`, `web::take_flash`, `web::page_meta`); `examples/pages` rebuilt as a multi-page app with sessions and CSRF.
- Next: typed configuration from environment variables.

## Milestone 2.6: routing and edge middleware

- [x] Wildcard path parameters `*name` for the rest of a path, ranked below static and `:param` segments.
- [x] Typed path parameters: `param_u64`, `param_uuid` (8-4-4-4-12, one letter case) and `param_slug`, all 422 `invalid_param`.
- [x] Host-scoped routes with `c.host(...)`: exact names and one-label `*.example.com` patterns, port stripped, case-insensitive; documented in OpenAPI like other routes.
- [x] Peer address on `Request.peer` and `c.peer()`, filled from `getpeername` at accept.
- [x] `rate_limit` (fixed window per client, bounded to 1024 clients, 429 with `Retry-After`) and `secure_headers` (CSP, nosniff, DENY, referrer policy, optional HSTS).
- Next: token-bucket limits. Shared counters within one host are done (the shared store); across hosts they remain open.


## Milestone 2.7: development loop

- [x] `scripts/dev.py`: rebuild and restart on save (inotify on Linux, polling elsewhere), debounced, with the old server kept on a failed build.
- [x] Browser live reload: `web::live_reload` injects the reload script only when `GOOSE_WEB_LIVE_RELOAD` is set; `reload` and `error` (overlay with the compiler output) events over SSE.
- [x] The starter and the pages example use it; `new_project.py` copies `scripts/dev.py` into a new project.
- Next: watch the imported package when it is fetched from GitHub; a file-change debounce tuned by measurement; reload of only the changed template.
## Milestone 2.7: security review and authentication

- [x] Security review with a threat model, a findings table with severity and status, and the fixes: [docs/security.md](docs/security.md).
- [x] Static files keep symbolic links inside the served root; a link that leaves it answers 404.
- [x] Process signals and reaps refuse pid 0 and negative pids; `getrandom` treats a zero return as failure; socket calls refuse negative lengths.
- [x] JSON strings must be valid UTF-8 after escapes are decoded (a lone `\uD800` is refused); `redirect_local` accepts only local paths.
- [x] PBKDF2-HMAC-SHA256 password hashing (RFC 7914 and published vectors, 600000 iterations by default, constant-time verification).
- [x] HTTP Basic and Bearer middleware (`basic_auth`, `bearer_auth`) that store the verified subject for `c.auth_subject()`; HMAC-signed tokens with expiry, deliberately not JWT.
- [x] Fuzzing for the JSON decoder and encoder, query, cookie and form parsing, template rendering with hostile data, and static path resolution, with recorded seeds; clang libFuzzer and AddressSanitizer harnesses for the base64url/HMAC/PBKDF2 and SQLite shim argument handling.
- Next: a server-side session store with revocation, login lockout guidance, and coverage-guided fuzzing in CI.

## Milestone 3: protocol and platform coverage

- [x] Strict request profile, malformed-input/prefix regressions, and deterministic parser fuzz/property checks.
- [x] Pinned upstream compiler and Linux CI definition for GCC and Clang.
- Broader conformance and coverage-guided fuzzing before public deployment.
- [x] Keep-alive with explicit idle, per-request, and per-connection limits.
- [x] Memory per connection: input storage grows from 1 KiB on demand and is returned when idle; the SSE outbox is reactor-owned and allocated on first publish (hello starts at 3.2 MB, down from 4.4 MB).
- [x] Many idle keep-alive connections do not delay other clients (integration test at `max_clients`).
- Chunked encoding for general streaming bodies with explicit ownership/backpressure (server-sent events are done).
- [x] Linux epoll readiness behind one reactor API (level-triggered, registration per connection), poll kept as the portable fallback.
- [x] Pre-forked worker processes (`workers`): shared listener, one reactor per worker, supervised restarts with backoff, graceful drain, aggregated stats; per-worker state and SQLite connections opened after fork are documented.
- [x] Shared state across workers: a bounded shared store (entries, counters, `rate_limit`, server-side sessions, server-sent events across workers) with a robust lock; see [docs/api.md](docs/api.md#shared-store).
- [x] Shared store locking: the key/value table is striped (up to 16 robust mutexes, a key's hash picks one), the ring and the stream registry have their own locks, every lock wait is timed (`shared_lock_timeout_ms`, default 50 ms) so a stopped holder fails calls instead of stalling workers, and `web::shared_stats()` exposes the entry count, lock timeouts, recoveries and the lost-event count.
- Shared store follow-ups: a lock-free read path for entries, if profiling shows the stripe locks matter; and a stripe-spill rule so a full stripe can borrow a slot from a neighbour (today a key is refused when its own stripe is full).
- kqueue for BSD and macOS, and a Windows transport, measured under load.
- TLS integration and deployment guidance.
- [x] Custom TCP protocols (`web::tcp_serve`, `web::tcp_connect`): own readiness instance for up to 1024 connections, bounded write queues with pause/resume, lingering graceful close, line and length-prefixed framing, echo/chat/proxy examples, and socket tests (`tests/integration/tcp.py`).
- Follow-up: one reactor hosting HTTP and TCP listeners together (a shared token space, so one process can serve both); today they run in separate processes.
- Follow-up: TCP with worker processes (the pre-fork supervisor would need per-listener routing), and UDP (`udp_bind` with receive and send events).
- Follow-up: TLS for TCP through a terminating proxy in front, or a native TLS layer when the upstream compiler's crypto surface allows it.
- Follow-up: name resolution for `tcp_connect` without blocking the loop (a resolver thread or a worker job).

## Milestone 4: asynchronous application work

- [x] Typed worker jobs and completions: `web::job_pool` runs pure-Goose work on threads over bounded typed queues, with correlation ids, lost-job reports, worker restarts and shutdown joins; example `examples/jobs`.
- [x] Timers integrated with readiness: `web::every`, `after`, `cancel` and `due` run from the tick, and `hint_wakeup` wakes the reactor for the next due task.
- Cancellation of a running job, and cooperative task states.- Benchmarks covering slow clients, queue saturation, latency, and memory bounds.

Async network I/O is implemented now. Language-level async/await is not implied by
this roadmap: application suspension must fit the upstream compiler's memory model.
