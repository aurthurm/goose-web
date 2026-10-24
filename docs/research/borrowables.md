# What to borrow next: veb, Tokio/tower/axum, Pydantic, FastAPI/Fastify

Research notes (2026-10-24). Sources: [veb README](https://github.com/vlang/v/blob/master/vlib/veb/README.md),
[veb docs](https://modules.vlang.io/veb.html), [Pydantic fields](https://pydantic.dev/docs/validation/latest/concepts/fields/),
[Pydantic errors](https://pydantic.dev/docs/validation/latest/errors/validation_errors/),
[pydantic-settings](https://pydantic.dev/docs/validation/latest/concepts/pydantic_settings/),
[tokio::time](https://docs.rs/tokio/latest/tokio/time/index.html), [tower](https://docs.rs/tower/latest/tower/index.html),
[tower-http](https://docs.rs/tower-http/latest/tower_http/index.html), [axum extractors](https://docs.rs/axum/latest/axum/extract/index.html),
[hyper upgrade](https://docs.rs/hyper/latest/hyper/upgrade/index.html), [FastAPI dependencies](https://fastapi.tiangolo.com/tutorial/dependencies/),
[Fastify validation](https://fastify.dev/docs/latest/Reference/Validation-and-Serialization/), [Fastify hooks](https://fastify.dev/docs/latest/Reference/Hooks/).

## Constraints that shape every design

- Generics are type-only (reference.md section 8): no `Str<1, 200>` value parameters. Field constraints go in a
  per-type registration overload, like `json_key`.
- Function values cannot be stored: custom validators are overloads, not closures in a table.
- Struct defaults are invisible to reflection: "required" is declared explicitly or read from `present` bits.
- Handlers are synchronous on the reactor: a per-request *timeout* that preempts a handler is impossible.

## Ranked additions

| # | Addition | From | Value | Effort |
| --- | --- | --- | --- | --- |
| 1 | Field rules (`web::rules`) + `validate<T>` run by body/query/form | Pydantic Field/validators | High | Medium |
| 2 | Collect-all 422 with Pydantic-shaped `detail: [{loc, msg, type}]` | Pydantic errors, Fastify | High | Low-medium (codec must continue past field errors) |
| 3 | OpenAPI constraint keywords from the same rules table | Pydantic JSON Schema | High | Low after 1 |
| 4 | Typed app settings from env: `web::settings<T>(prefix)`, `*_FILE` secrets, all errors at startup | pydantic-settings | High | Low-medium |
| 5 | Structured JSON request logs (request_id, route, status, duration) | tracing-subscriber | Medium | Low |
| 6 | Trusted-proxy client IP (X-Forwarded-For allow-list) for logs and rate limits | veb `ctx.ip`, trusted_proxies | Medium | Low |
| 7 | ETag + If-None-Match → 304 (SHA-256 of buffered body) | RFC 9110 | Medium | Low |
| 8 | Load shedding by queue watermark (503 + Retry-After), concurrency limiter | tower load_shed, veb throttle | Medium | Low |
| 9 | gzip response compression (zlib via native shim), Vary, never for SSE | veb encode_auto, tower-http | Medium | Medium |
| 10 | Multipart/form-data uploads with per-part limits, slices into the request buffer | veb `ctx.files`, axum Multipart | Medium-high | Medium-high |
| 11 | WebSockets (101 upgrade, frames, ping/pong, close; fan-out like SSE; needs SHA-1) | hyper upgrade, axum, veb takeover_conn | High | High |
| 12 | Typed request locals / dependency helpers (`current_user(c)` + guard) | FastAPI Depends | Medium | Medium |
| 13 | Trailing-slash normalisation, cache-control and error-page helpers | tower-http normalize_path, veb | Low | Low |

Already in Goose Web: routing with groups/params/wildcards/hosts, strict body/query/form, json_key/json_skip,
OpenAPI, request_id/logger/cors/rate_limit/secure_headers, sessions, CSRF, templates, static files, keep-alive,
epoll, SSE, workers, SQLite. In progress: scheduler + jobs (covers FastAPI BackgroundTasks / tokio interval),
shared store, auth helpers, hot reload, TCP layer.

## Validation design (items 1-4)

```goose
struct NewNote { title: u8[..200], priority: i64 = 0, email: u8[..254], slug: u8[..64] }

fn web::rules(v: NewNote&, r: web::Rules&) {
    r.field("title").required().min_len(1).max_len(200);   // code points
    r.field("priority").ge(0).le(5);
    r.field("email").format(web::FORMAT_EMAIL);
    r.field("slug").pattern(web::PATTERN_SLUG);            // builtin matchers (no regex engine)
}
fn web::validate_model(v: NewNote&, out: web::Issues&) { /* cross-field checks */ }
fn web::normalize(v: NewNote&) { /* trim, lowercase */ }
```

- Generic default `web::rules` adds nothing; `web::check_rules<T>()` validates names/bounds at startup.
- `validate<T>` walks `fields<T>` and dispatches `check_value` overloads per type (text: lengths/pattern/format;
  integers and floats: ge/le/gt/lt/multiple_of; arrays: min/max items; nested structs: explicit overload).
- Pipeline in `body<T>`: strict decode → `normalize` → `validate` → 422 listing every issue:

```json
{"error":{"code":"invalid_payload","message":"title: String should have at least 1 character"},
 "detail":[{"loc":["body","title"],"msg":"String should have at least 1 character","type":"string_too_short"},
           {"loc":["body","priority"],"msg":"Input should be less than or equal to 5","type":"less_than_equal"}],
 "truncated":false}
```

- `error.message` stays the first issue, so existing clients keep working. Pydantic type ids where they apply
  (missing, string_too_short/long, greater_than(_equal), less_than(_equal), multiple_of,
  string_pattern_mismatch, extra_forbidden, int_parsing, value_error).
- Strict by default; `r.field(...).lax()` only for form/query (bool from on/yes/1).
- OpenAPI reads the same table: minLength/maxLength, minimum/maximum, exclusive*, multipleOf, min/maxItems,
  pattern (documentation string for builtins), format, `required`.
- `web::settings<T>("APP_")` reads `APP_<FIELD>` (and `APP_<FIELD>_FILE`), parses per type, applies the same
  rules, collects every problem, and redacts fields marked `.secret()`.

Biggest risk: the codec must record field-level errors and continue instead of stopping at the first.
