# Changelog

All notable changes to Goose Web. Versions follow [Semantic Versioning](https://semver.org/) with
the usual 0.x caveat: until 1.0.0, a minor release may change the public API, and every such change
is listed under **Breaking** here. The release steps are in [docs/releasing.md](docs/releasing.md).

The entries before 0.6.0 were design milestones, not published releases. They are reconstructed
from [ROADMAP.md](ROADMAP.md) and the design notes in [docs/design/app-api.md](docs/design/app-api.md),
because the repository has no tag history for them.

## Unreleased

### Added

- `ServerConfig.worker_restart_budget` (default 30, the largest accepted value): the number of
  unexpected worker restarts tolerated within 60 seconds. Spending it stops the server, writes a
  message to stderr and makes `serve_config` return false. The default is unchanged.
- Worker supervisor tests over real processes (`tests/integration/workers.py`): the restart budget
  stops the server with a nonzero exit, a worker held past the shutdown grace is SIGKILLed 500 ms
  after it and no worker survives, and the stats of a crashed worker are lost while the others are
  summed. The fixture takes an optional restart budget and a `/block` route.
- Stats record unit test (`tests/unit/stats_record.goose`): every `ServerStats` field round-trips,
  and a frame with a wrong field count, magic or length is rejected.

- Reactor scheduler (`web::scheduler`, `every`, `after`, `cancel`, `due`, `hint_wakeup`): bounded periodic and
  one-shot tasks run from the tick, monotonic times, documented catch-up rule. `ServerControl.wake_at_ns` shortens
  the poll wait to the next due task. See [Scheduler](docs/api.md#scheduler).
- Background job pool (`web::job_pool`, `job_start`, `job_submit`, `job_drain`, `job_stop`, `job_worker`): pure-Goose
  work on contained worker threads over typed queues, with a bounded queue (503 when full), correlation ids, lost-job
  reports and worker restarts. See [Background jobs](docs/api.md#background-jobs) and [examples/jobs](examples/jobs/README.md).

- Structured request logs: `json_logger(c, include_query = false) { }` prints one JSON object per request (RFC 3339 UTC `ts`, `level`, `request_id`, `method`, `path` without the query by default, the matched `route` pattern, `status`, `bytes`, `duration_us`, `peer`, `client_ip`, a truncated `user_agent`, `pid` in worker processes). Values are JSON-escaped. `c.route_pattern()` gives the matched pattern. See [Structured logs](docs/api.md#structured-logs).
- Trusted proxies: `trusted_proxies("10.0.0.0/8, ::1")` builds an allow-list of up to 16 IPv4, IPv6 or CIDR entries; `trust_proxies(c, cfg) { }` resolves the client from `X-Forwarded-For` (or RFC 7239 `Forwarded` with `cfg.forwarded = true`) only when the TCP peer is trusted; `client_ip(c)` returns the result. `rate_limit` counts the client address. See [Trusted proxies](docs/api.md#trusted-proxies).
- ETag and conditional GET: `etag(c) { }` gives 200 GET and HEAD responses a strong tag (SHA-256 of the body, first 16 bytes, base64url), and answers `If-None-Match` (lists, `*`, weak comparison) with 304 and no body or Content-Type. `cache_control(c, value)` sets `Cache-Control`. See [ETag](docs/api.md#etag).
- Load shedding: `shed_load(c, LoadPolicy { ... }) { }` answers 503 `overloaded` with `Retry-After` when the reactor reports connection or response-pool pressure above the policy. The reactor publishes `live_pressure` before each handler; `c.server_pressure()` exposes it. `body_limit(c, bytes) { }` answers 413 `payload_too_large` for a longer body. See [Load shedding](docs/api.md#load-shedding).
- Custom TCP protocols: `web::tcp_config`, `web::tcp_serve`, `web::tcp_connect` and the connection functions in `src/net/tcp.goose`, with framing helpers in `src/net/framing.goose`. Own readiness instance in `native/posix/net.c`. Examples `examples/tcp-echo`, `examples/tcp-chat`, `examples/tcp-proxy`. See the TCP section of `docs/api.md`.

### Changed

- The worker stats record is a fixed-size frame (`STATS_RECORD_BYTES`, 272 bytes): a magic word
  `GWSTATS1`, the field count, then each `i64` field as little-endian bytes. It is encoded and
  decoded with `const for` over `fields<ServerStats>`, and the parent sums with the same walk, so a
  new field is carried without other edits. The hand-counted `96`-byte record is gone. The pipe
  moves opaque bytes, and the record format is internal to the build (parent and workers are one
  binary).
- The parent drops a stats frame that does not match its build instead of adding it.
- A response may have an empty `content_type` only when its status is 304; that response is serialized without
  `Content-Type` (RFC 9110 15.4.5). Every other response still needs one.

## 0.6.0

First release that can be consumed as a fetched package (`import goose_web from "aurthurm/goose-web@v0.6.0";`).
The version constant is `web::VERSION`, and it must match the `VERSION` file (`tests/run.py` checks this).

### Added

- Consumption documentation: the repository root is an importable package (`goose_web`), and `db/`
  is the `goose_web_db` package. See [README](README.md#use-it-in-your-project).
- `web::VERSION` and the `VERSION` file.
- Signed cookie sessions (`session`, `session_get`, `session_set`, `session_clear`) and double-submit
  CSRF protection (`csrf`, `c.csrf_token()`), with native HMAC-SHA256, SHA-256, CSPRNG and base64url.
- Routing extras: `*name` wildcards, `c.host(...)` scopes, typed path parameters `param_u64`,
  `param_uuid` and `param_slug`.
- Peer address (`c.peer()`, `Request.peer`) and edge middleware `rate_limit` and `secure_headers`.
- Typed `query<T>` and `form<T>` binding, `json_key` and `json_skip` for field names and skipping.
- Starter project in `templates/starter` and the generator `scripts/new_project.py`.
- Documentation site in `docs/site` (published with GitHub Pages).

### Changed

- Per-request state (route table, sessions, CSRF, OpenAPI configuration) moved out of the per-request
  `Ctx` into an application-owned scratch that `run` manages. Application code is unaffected; code
  that built a `Ctx` by hand must now pass an `AppScratch` to `new_ctx`.

### Security notes

- Sessions are signed, not encrypted, and have no server-side revocation: a copied cookie stays valid
  until `max_age`. See the Sessions section of [docs/api.md](docs/api.md#sessions).
- The CSRF cookie has no `Secure` attribute yet; serve forms over HTTPS.
- Rate limits are per process and per client address; they are not shared between instances.

## Earlier milestones

### 0.5 design: server-sent events

- `c.sse(channel)` upgrades a route to a chunked `text/event-stream`, `web::sse_publish` fans events
  out per channel, heartbeats, bounded per-stream queues that drop slow readers, and close events at
  shutdown. Example: `examples/sse-clock`.

### 0.4 design: reflective SQLite layer

- `db/` (`goose_web_db`): CRUD from `fields<T>` with bound parameters, a query builder,
  transactions, migrations with `schema_version`, WAL file databases. Example: `examples/sqlite-todos`.
  Calls run on the reactor thread.

### 0.3 design: growable responses and OpenAPI

- Response bodies grow on demand up to `max_response_bytes` (1 MiB default, 16 MiB ceiling), in a pool
  bounded by `max_pool_bytes`.
- OpenAPI 3.1 generated from the routes block and struct reflection, served at `/openapi.json` with a
  `/docs` page.
- Keep-alive connections with explicit idle and per-connection limits.
- Compile-time HTML templates (`embed_file`, `html_template`, `check_template`) and `form<T>`.

### 0.2: application API

- `c.routes()` and `c.group`, path parameters, automatic 404 and 405 with `Allow`.
- Reflective JSON codec (`json_encode`, strict `json_decode<T>`), typed bodies (`body<T>`), JSON
  responses, built-in middleware (`request_id`, `logger`, `cors`, `require_json`).
- Static files as middleware, cookies (`c.cookie`, `c.set_cookie`), validated runtime configuration,
  `config_from_args` and `config_from_env`.

### Milestone 1: foundation

- Nonblocking accept, read and write with poll readiness, partial writes and bounded client slots.
- HTTP/1.1 parsing and response framing with explicit limits and deadlines.
- Typed queued event bus with subscribe, once, arguments and visible backpressure.
- Graceful shutdown on SIGINT and SIGTERM.
