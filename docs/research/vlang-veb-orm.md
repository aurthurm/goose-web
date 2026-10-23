# Lessons from V's veb web framework and ORM

Research notes (2026-10-23) on what Goose Web can borrow from V's built-in web stack.
Sources: [veb source](https://github.com/vlang/v/tree/master/vlib/veb),
[veb module docs](https://modules.vlang.io/veb.html), [veb.csrf](https://modules.vlang.io/veb.csrf.html),
[V ORM](https://docs.vlang.io/orm.html), [V JSON](https://docs.vlang.io/json.html).

## What V does

- **Routing**: attributes on app methods, `@['/hello/:user'] fn (app &App) hello(mut ctx Context, user string)`;
  path params are cast to the parameter type; `/:path...` wildcards; `host:` routing; 405 + Allow.
- **Context**: per-request struct embedding `veb.Context` plus app-defined fields; app struct holds shared state.
- **Middleware**: `app.use(...)` global, `app.route_use(route, ...)` per route, `after` flag; built-ins for
  CORS, gzip/zstd, throttle, rate limit, secure headers, request id, SSE.
- **Results**: handlers return `veb.Result` from `ctx.text/html/json/redirect/file/not_found/...`;
  `!veb.Result` errors become a JSON 500 unless a status was set.
- **Controllers**: sub-apps mounted at a prefix or host.
- **Templates**: compiled into the binary, so template errors are compile errors (`$veb.html()`).
- **CSRF**: stateless double-submit cookie with an HMAC-signed token; safe methods skipped.
- **ORM** (alpha; SQLite/MySQL/Postgres): `@[table]`, `@[primary; serial]`, optional `?T` columns;
  `sql db { create table T }`, `insert x into T`, `update T set ... where ...`,
  `select from T where a == b && c > 0 order by id desc limit 10`, `select count`.
- **JSON**: compile-time reflection; `@[json: name]`, `@[skip]`, `@[required]`.

## What maps onto Goose

Goose has no attributes, no runtime reflection, no stored closures, and shares no memory between
threads. It does have `const for` over `fields<T>`, overload-based type dispatch, compile-time
`embed_file("path")` (reference.md section 21), and `extern fn` to C. SQLite 3.46 headers are present on the dev box.

| V feature | Goose Web today | Borrow? |
| --- | --- | --- |
| Attribute routing | `c.get/post(...)` DSL (explicit, no reflection needed) | Keep the DSL |
| Typed params `:id` → int | `c.param_int` | Add more typed accessors |
| Wildcard `/:path...` | none | Yes, router token (both passes must agree) |
| `host:` routes | none | Yes, `c.host("api.x") { ... }` block |
| Global / per-route / after middleware | lexical nesting covers all three | Already have |
| Controllers / sub-apps | `c.group` + plain functions | Already have |
| Context embedding | fixed `Ctx` | Typed per-request locals via a registered app struct |
| Throttle / rate limit / secure headers | none | Yes, small middleware with fixed tables |
| Compile-time templates | none | Yes, via `embed_file` + a tiny compile-time-checked renderer |
| CSRF + signed sessions | none | Yes, needs HMAC-SHA256 + CSPRNG (C shim) |
| JSON rename/skip | none | Yes, registration overloads like `json_put_value` |
| ORM | none | Yes: reflective SQLite layer over the C API |
| Gzip | none | Later (needs deflate) |

## Ranked proposals

1. **Reflective SQLite layer** (high value, medium-high effort). `create_table<T>`, `insert`, `update`,
   `delete`, `select<T>` with bound parameters only, column names checked against `fields<T>`,
   primary key by registration overload, ordered migrations with a `schema_version` table, and
   `transaction(db) { ... }` as a block. C shim in `native/` around `sqlite3_*` (text crosses as
   `{data,len}`, so the shim binds with explicit lengths and `SQLITE_TRANSIENT`). Calls block the
   reactor: document WAL and short queries; worker-thread offload later (flat values only).
2. **JSON field rename/skip** (high value, low effort): `fn web::json_key(v: T&, field) -> const u8[:]`.
3. **Compile-time templates** (medium-high value, medium effort): `embed_file("views/index.html")` gives
   the template bytes at compile time; a small renderer with `{{name}}` (escaped) and `{{{name}}}` (raw)
   filled from a struct by `fields<T>` reflection. HTML escaping by default.
4. **CSRF + signed cookie sessions** (high value for forms, medium effort): HMAC-SHA256 and `/dev/urandom`
   in the native shim; middleware shape `web::csrf(c, secret) { ... }`.
5. **Wildcards, host blocks, more typed params** (medium value, low effort).
6. **Rate limit / secure headers middleware** (medium value, low effort).
7. **Typed request locals** (medium value, low-medium effort).

Risks: blocking I/O on the reactor thread (SQLite); crypto must be correct (prefer vetted C);
every V attribute becomes a per-type registration overload in Goose, which needs validation helpers
so mistakes fail loudly.
