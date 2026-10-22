# Goose Web Roadmap

**Status:** Experimental / pre-alpha. This is a capability roadmap, not a claim that the framework is production ready.

## Design principles

- **API first:** minimal route and response API inspired by Fastify, FastAPI and Axum.
- **Goose first:** request routing, responses, validation and middleware in Goose; native C only where necessary.
- **Safe and bounded:** explicit limits, no unchecked pointers in Goose, closed connections by default, robust error codes.
- **Composable:** small core, opt-in middleware/plugins, zero runtime reflection, no forced ORM or dependency injection.
- **Honest performance:** prove throughput, p95/p99 latency and memory usage in reproducible benchmarks.
- **Portable:** bring up POSIX first, then Windows, without breaking public APIs.

## Milestone M0 — repository bootstrap (in progress)

- [x] Project charter, license and contributor guidance
- [x] Architecture and extension model written down
- [x] Initial Goose-only route matching module and tests drafted
- [x] Native transport experiment and hello-world example drafted
- [ ] Verify Goose compilation against a pinned upstream compiler revision
- [ ] Exercise HTTP smoke tests on Linux and record results

**Exit criteria:** `goose check`, build and smoke-test run cleanly against a recorded Goose commit; reproducible instructions and CI check.

## Milestone M1 — HTTP/1.1 alpha (v0.1)

- [ ] Request line, header and bounded body parsing; reject ambiguous/malformed requests
- [ ] GET/POST/PUT/PATCH/DELETE/HEAD/OPTIONS
- [ ] Static and parameterized router, query parameters and route groups
- [ ] Response helpers, headers, status and JSON encoding
- [ ] Robust content-length, transfer-encoding and timeout handling (prevent request smuggling)
- [ ] Safe connection lifecycle, graceful shutdown and structured errors
- [ ] Linux/macOS and Windows transport implementation
- [ ] CI, integration tests, fuzz tests and comparative benchmark harness

**Exit criteria:** correctly implemented bounded HTTP/1.1 lifecycle, safety tests and sustained concurrency evidence. No public stable API promise yet.

## Milestone M2 — developer experience (v0.2)

- [ ] Typed JSON bodies and typed response serialization
- [ ] Typed path/query/header extraction and validation errors
- [ ] Middleware composition, before/after hooks and error hooks
- [ ] Route groups, prefixes, nesting and per-group middleware
- [ ] Generated OpenAPI 3.1 docs with opt-in Swagger UI
- [ ] Cookie, CORS, request-ID and tracing plugins
- [ ] Developer-facing examples and API documentation

**Exit criteria:** REST CRUD example using framework-only building blocks and automatically generated API contract.

## Milestone M3 — concurrency and realtime (v0.3)

- [ ] Benchmarked event-loop/worker integration compatible with Goose's isolated workers
- [ ] Explicit backpressure and streaming response support
- [ ] Server-Sent Events, WebSockets and cancellation
- [ ] TLS integration; HTTP/2 feasibility proof
- [ ] Database-driver interoperability patterns
- [ ] Concurrency/load tests and fault injection

**Exit criteria:** documented isolation, fairness, bounded memory and measurable performance.

## Milestone M4 — stable ecosystem (v1.0)

- [ ] Published extension API and SemVer compatibility policy
- [ ] Security audit, hardening and deployment documentation
- [ ] Stable C ABI boundary and cross-platform packaging
- [ ] Extensions: auth, rate limits, metrics, multipart, compression
- [ ] Docker examples, observability, regression benchmarks and upgrade guides

**Exit criteria:** proven compatibility suite, production-readiness checklist and stable docs.

## Backlog / non-goals

Not part of the core: ORM, migrations, full application scaffolding, background scheduler, template engine, admin UI. These should be separate packages if demand emerges.

## Risks and decisions

1. **Compiler maturity:** Goose changes quickly. Pin revisions for CI and maintain a compatibility matrix.
2. **No escaping closures or ordinary dynamic function pointers:** prefer static/compile-time route composition. Validate syntax before promising ergonomic `app.get` helpers.
3. **Request ownership:** C buffers and Goose slices must never outlive each other. Prefer copy-in and bounded per-request data in the first implementation.
4. **Concurrency:** isolated worker queues require careful measurement; do not assume zero-copy or async semantics.
5. **Security:** the bootstrap transport is not a complete HTTP server. Put it behind a reverse proxy only for local experiments; do not deploy publicly.
