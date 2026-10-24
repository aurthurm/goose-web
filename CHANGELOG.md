# Changelog

All notable changes to Goose Web. Versions follow [Semantic Versioning](https://semver.org/) with
the usual 0.x caveat: until 1.0.0, a minor release may change the public API, and every such change
is listed under **Breaking** here. The release steps are in [docs/releasing.md](docs/releasing.md).

The entries before 0.6.0 were design milestones, not published releases. They are reconstructed
from [ROADMAP.md](ROADMAP.md) and the design notes in [docs/design/app-api.md](docs/design/app-api.md),
because the repository has no tag history for them.

## Unreleased

### Added

- Authentication: `hash_password`, `hash_password_iterations` and `verify_password` (PBKDF2-HMAC-SHA256,
  600000 iterations by default), `basic_auth` and `bearer_auth` middleware with `c.auth_subject()`,
  and `sign_token` and `verify_token` (HMAC-signed tokens, not JWT). See [docs/api.md](docs/api.md#authentication).
- `redirect_local`, which accepts only local paths for targets taken from a request.
- Fuzz programs for JSON, query, cookie and form parsing, template rendering and static paths, and clang
  libFuzzer harnesses for the C byte-slice and SQLite shims.

### Changed

- Static files: a symbolic link whose real target lies outside the served directory answers 404. Links
  that stay inside are still followed.
- JSON decoding refuses a string whose escapes decode to bytes that are not valid UTF-8 (for example a
  lone `\uD800`).

### Security notes

- The security review, its findings and their status are in [docs/security.md](docs/security.md).
  Fixed in this release: static-file symlink escape, signalling and reaping pid 0 or a negative pid,
  a `getrandom` zero-return loop, negative lengths in socket calls, and invalid UTF-8 from JSON escapes.

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
