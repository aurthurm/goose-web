# Application API (v0.2 design)

Status: implemented (v0.2). See "Implementation notes" at the end for compiler-forced deviations. The low-level API in [api.md](../api.md)
stays public; this layer is built entirely on it.

## Goal

Make Goose Web feel like FastAPI / Fastify / axum while staying honest about Goose:
function values are compile-time only (no stored closures, no function pointers), so
routes and middleware are *code*, not data. That turns out to be a strength: every
route call is direct and inlinable, and the whole app is one ordinary function.

## North-star example

```goose
import goose_web from "../..";
import std;

struct Health { status: u8[..16] }
struct TodoIn { title: u8[..200], completed: bool = false }
struct Todo { id: i64, title: u8[..200], completed: bool }

var todos: Todo[..100] = [];
var next_id: i64 = 1;

fn todo_routes(c: web::Ctx&) {
    c.get("/") { c.json_list(todos[..]) };            // arrays/slices use json_list
    c.post("/") {
        let input, ok = body<TodoIn>(c);               // 415 / 400 / 422 written for you
        guard ok else { return; }
        let item = Todo { id: next_id, title: input.title, completed: input.completed };
        next_id += 1;
        todos.push(item);
        c.status(web::HTTP_CREATED).json(item);
    };
    c.get("/:id") {
        let id, ok = c.param_int("id");                // 422 invalid_param written for you
        guard ok else { return; }
        for t in todos { if t.id == id { c.json(t); return; } }
        c.fail(web::HTTP_NOT_FOUND, "todo_not_found", "Todo not found");
    };
}

fn app(c: web::Ctx&) {
    request_id(c) { c.logger() { c.cors() {
        c.routes() {                                   // 404 / 405 + Allow handled here
            c.get("/health") { c.json(Health { status: "ok" }) };
            c.group("/todos") { todo_routes(c) };
        };
    }}};
}

fn main() {
    var config = web::server_config();
    config.port = 8080;
    if !web::run(config) { c => app(c) } { abort("server failed"); }
}
```

## Core concepts

### `Ctx` (src/app/context.goose)

One value per request, built by `new_ctx` for the duration of the handler. The request view and
the response are borrowed; routing, session, CSRF and OpenAPI state live in an `AppScratch` that
the caller owns and `Ctx` refers to (see Implementation notes, v0.6).

```goose
struct Ctx {
    request: Request,          // borrowed views, valid only during the handler
    response: Response&,      // borrowed; serialized after the app returns
    matched: RouteMatch,       // path params of the selected route (bounded, MAX_PATH_PARAMS)
    table: Router&,            // route table, in the AppScratch
    session_state: SessionState&, csrf_state: CsrfState&, oas: OpenApiState&,
    oas_text: u8[>..],         // OpenAPI describe text, per request (last field)
}
```

Accessors (all UFCS-callable, `c.x(...)`):

| Function | Meaning |
| --- | --- |
| `c.method()`, `c.path()`, `c.target()`, `c.header(name)` | request views |
| `c.param(name) -> const u8[:]` | path parameter of the matched route, "" if absent |
| `c.param_int(name) -> i64, bool` | canonical positive/zero decimal; on failure writes 422 `invalid_param` and returns false |
| `c.query(key) -> QueryValue` | wraps `query_value`; `c.query_int(key, default) -> i64, bool` writes 400 `invalid_query` on failure |
| `c.status(code) -> Ctx&` | sets status, returns ctx for chaining |
| `c.set(name, value) -> Ctx&` | `set_header`; asserts in debug on invalid header |
| `c.text(body)`, `c.html(body)`, `c.json_raw(body)` | set content type + body; over-capacity body → 500 `response_too_large` |
| `c.json(value)` | reflective encode of any supported value (see JSON) |
| `c.no_content()` | 204, empty body |
| `c.redirect(location, status = 302)` | |
| `c.fail(status, code, message)` | `application_error` JSON envelope |
| `c.done() -> bool` | true once a handler/middleware wrote a response (status set or body written); middleware use it to short-circuit |

### Routing DSL (src/app/routes.goose)

`c.routes() { ... }` runs its block **twice**:

1. *match pass*: each `c.get/post/put/patch/delete/head/options/any(pattern) { body }`
   only records whether `prefix + pattern` matches the request path and its
   specificity. Bodies do **not** run.
2. The best route is selected with the existing rules from `router.goose`
   (most specific path first, then method; explicit HEAD wins, else GET serves HEAD;
   static segments beat params; no method fallthrough). If no path matched → 404
   `not_found`; path matched but no method → 405 `method_not_allowed` with `Allow`.
3. *dispatch pass*: the block runs again; only the selected route's body runs, with
   path params bound into `Ctx`.

Consequences, documented for users:
- Code inside `c.routes() { }` but outside a route body runs twice — keep it
  declarative (route calls, `c.group`, calls to functions that declare routes).
- Routes are identified by declaration order, so the block must declare the same
  routes on both passes (no conditionals based on mutable state between passes).
- `c.group(prefix) { ... }` pushes a path prefix (bounded stack) for nested routes.
- Patterns are validated with `route_pattern_valid`; an invalid pattern is a
  programmer error → `abort` with the pattern in the message (fail fast at first request;
  `web::check_routes(app)` can be called in tests/startup to validate eagerly).
- `return` inside a route body returns from the enclosing *named* function (Goose block
  semantics), which ends that route — this is the intended early-exit idiom.

### Middleware (src/app/middleware.goose)

Middleware is any function `fn name<Next>(c: Ctx&, ...) { before; Next(); after; }`.
Not calling `Next()` short-circuits. Composition is lexical nesting. Built-ins:

| Middleware | Behavior |
| --- | --- |
| `request_id(c) { }` | increments a counter, sets `X-Request-ID`, stores it in `c.request_id` |
| `logger(c) { }` | after Next: prints `METHOD path status bytes` (one line) |
| `cors(c, origin = "*") { }` | sets `Access-Control-Allow-*`; answers OPTIONS preflight with 204 without calling Next |
| `require_json(c) { }` | 415 unless Content-Type is application/json (params ignored) |

### JSON codec (src/json/codec.goose)

Reflective via `const for <N, A> in fields<T>`; zero metadata, monomorphized.

- `json_encode(out: u8[>..]&, value)` — supports i8..i64, u8..u64 (as numbers), f32/f64,
  bool, strings (`u8[..N]`, `u8[>..]`, `const u8[:]`), nested structs, arrays/slices of
  any supported type (→ JSON arrays). Strings must be valid UTF-8 (else encode fails →
  500). Field names are emitted as declared.
- `json_decode<T>(text) -> T, DecodeResult` — strict object decoding into struct `T`:
  unknown keys, duplicate keys, wrong types, overlong strings (`.cap`), integer overflow
  for the field type, invalid UTF-8 and trailing input are errors. **Missing keys keep
  the field's declared default**, and `DecodeResult.present` is a bitmask (field order)
  so PATCH handlers can ask `result.has<T>("title")`. `DecodeResult { ok, error:
  u8[..128], field: u8[..64] }` — the first error, human-readable.
- `c.body<T>() -> T, bool` — Content-Type check (415 `unsupported_media_type`), decode,
  on failure 400 `invalid_json` (syntax) or 422 `invalid_payload` with the field name
  in the message. Returns the `DecodeResult` too via `c.body_result<T>()`.

### Running (src/app/run.goose)

- `web::run(config) { c => app(c) } -> bool` — builds a Ctx per request inside
  `serve_config`'s handler, calls the app, copies `c.response` back. No tick/lifecycle.
- `web::run_with(config, control, app, tick, lifecycle) -> bool` — full control, for
  apps using the event bus.

## Goose gotchas found while prototyping (read before writing code)

- A parameter `u8[..N]` cannot be generic over `N` ("array capacity N names a type
  parameter"). For reading, take `const u8[:]`; for writing into any limited string,
  use a generic `out: T&` overload and `out.cap` / `out.clear()` / `out.append(s)`.
- Overload resolution prefers concrete overloads (`i64&`, `bool&`) over a generic `T&`
  fallback — use that for type dispatch in the codec.
- Variable-size values (`u8[>..]`) are not copied implicitly: `return copy(x);`.
- UFCS: `fn get<F>(c: Ctx&, p: const u8[:])` is callable as `c.get("/x") { ... }`.
  One trailing block per call; a second function value is passed by name.
- A block's `return` returns from the lexically enclosing named function.
- Language docs: `/opt/goose/docs/reference.md` (concise), `goose_spec.md` (full),
  `stdlib.md`; samples in `/opt/goose/samples/`; stdlib JSON in `/opt/goose/stdlib/json.goose`.
  These match the pinned compiler `4d3da949e563`.

## Implementation notes (compiler-forced deviations)

- Explicit type arguments are not allowed on UFCS calls: write `body<T>(c)`, not `c.body<T>()`.
- `c.json(value)` takes a struct or scalar; arrays and slices go through `c.json_list(xs[..])`
  (a slice overload of `json` is ambiguous with the generic by-value one).
- `c.request_id()` is shadowed by the `Ctx.request_id` field: write `request_id(c) { ... }`.
- App-facing functions are reachable as `c.x()` through global forwarders in `src/app/dsl.goose`
  because Goose resolves UFCS in the caller's namespace.
- Nested structs need a registered `web::json_put_value` / `web::json_read_value` pair (see api.md):
  Goose has no compile-time predicate to tell a struct from a limited string.
- When the match pass yields 404/405 the dispatch pass is skipped.

## v0.3 design: growable response body

Problem: `Response.body` is an inline `u8[..MAX_RESPONSE_BODY_BYTES]`, so every request pays
for the full capacity (1 MiB measured ~4x slower than 8 KiB; ceiling is 64 KiB today).

Decision (prototyped and compiling): `Response.body` becomes an owned grow array `u8[>..]` plus
`body_start: i64`. The *current* body is `body[body_start..]`.

- Within a request the buffer is **append-only**. Replacing the body appends the new bytes and
  moves `body_start` to where they begin. Goose's checker refuses `clear()`/shrink on a value while
  any slice that might alias it is live (`text(c, c.param("x"))` would be rejected), but growing is
  allowed. This also makes `set_body(r, body_of(r))` safe.
- The server truncates/clears the buffer after the handler returns and the response is serialized,
  when no views are live. Memory is proportional to what the request actually wrote.
- All writes go through functions: `set_body(r, text) -> bool`, `append_body(r, text) -> bool`,
  `body_of(r) -> const u8[:]`, `body_len(r) -> i64`. Each enforces a per-response cap
  (`r.max_body`, set by the runtime from `config.max_response_bytes`; default 1 MiB, ceiling 16 MiB)
  and returns false at the cap; app helpers turn that into 500 `response_too_large`.
  Direct `r.body = ...` / `r.body.len` uses in src, examples and tests are migrated.
- `Response`/`Ctx` are no longer fixed-size: pass by reference (`App(&c)` already does), and use
  `copy()` where a copy is really wanted. The runtime hands the handler a Response it owns per
  connection slot or a single reactor-owned scratch Response reused across requests (handlers are
  synchronous; only one runs at a time).
- Acceptance: hello benchmark (3000 fresh connections, `GET /health`) within 10% of the 8 KiB
  build (~11k req/s on the dev box), and a 1 MiB body round-trips intact over a socket.

Implementation notes (v0.3, as built):

- `Response` is `{ status, content_type, headers, body_start, max_body, body: u8[>..] }`; the body is the
  last field. `Ctx.response` is `Response&`, so `Ctx` stays fixed-size and the runtime passes its one
  reused scratch response into every handler (no per-request copy back). Tests own the response they
  build a `Ctx` on.
- Cap: `max_body` bounds every byte the buffer holds, including replaced bodies. Error envelopes may
  exceed it by `MAX_ERROR_BODY_BYTES`, so a refused write can still be replaced by its 500.
- Pool: serialized responses are linked chunk lists (`pool.next`), and a connection slot keeps only its
  head chunk, so 64 idle slots cost no response storage. The head is serialized into a reused buffer and
  the body is copied straight from the scratch response, so there is no 16 MiB wire buffer.
  `max_pool_bytes` (default 8 MiB, validated to hold one maximal response) caps the pool; when a response
  does not fit, the runtime answers 503 `Service Unavailable` and closes the connection.
- Memory bound: scratch body capacity (up to `max_response_bytes`, 16 MiB ceiling) + pool
  (`max_pool_bytes`, 64 MiB ceiling) + head buffer (under 8 KiB) + 8 KiB input per slot.

## v0.3 design: OpenAPI from routes and structs

Goal: FastAPI-style `/openapi.json` (+ a `/docs` page) generated from the same `c.routes()` block.

- A third routing pass, **describe**, runs the routes block without executing bodies; each route
  call appends an operation (method, path with `:id` → `{id}` and a string path parameter).
- Annotations are plain calls placed *before* the route they describe; they are no-ops in the match
  and dispatch passes and attach to the next route in the describe pass (generic type args need the
  non-UFCS form):

```goose
c.routes() {
    web::summary(c, "Create a todo");
    web::accepts<TodoIn>(c);                    // requestBody application/json schema
    web::returns<Todo>(c, web::HTTP_CREATED);   // response schema per status
    c.post("/todos") { ... };
    web::returns_list<Todo>(c, web::HTTP_OK);   // array schema
    web::query_params<ListQuery>(c);            // query parameters from struct fields
    c.get("/todos") { ... };
};
```

- Groups contribute their prefix and a default tag (the first prefix segment). `web::tag(c, name)`
  overrides.
- Schemas come from `fields<T>` reflection: ints → `integer` (with min/max for the width), floats →
  `number`, bool → `boolean`, `u8[..N]` → `string` with `maxLength: N`, limited arrays → `array`
  with `maxItems`. Fields with declared defaults are optional, others required: since reflection
  cannot see defaults, compare against `default<T>()` is NOT used; instead every field is listed in
  `required` unless `T` provides `fn web::optional_fields(v: T&) -> const u8[:]` (comma list) —
  same registration idiom as nested structs, which also need a `json_schema_value` overload.
  Schemas are inline (no `$ref`; Goose cannot reflect type names).
- Every operation also documents the framework's error envelope for 400/404/405/415/422/500.
- Wiring: `web::openapi(c, OpenApiInfo { title: "Todo API", version: "1.0", .. }) { c.routes() { ... } }`.
  It sets ctx fields so `routes()` answers `GET /openapi.json` (JSON, OpenAPI 3.1) and
  `GET /docs` (a small HTML page loading a pinned Scalar or Swagger UI from a CDN) by running
  the describe pass. Paths configurable in `OpenApiInfo`.
- Output must stay within the response cap; generation is pure and testable via a unit test that
  validates the JSON parses and contains expected paths/schemas.

## v0.4 design: reflective SQLite layer (`web::db`)

Inspired by V's ORM (see [research notes](../research/vlang-veb-orm.md)); Goose has no attributes or
SQL-in-syntax, so the mapping comes from `fields<T>` reflection plus per-type registration overloads.
Prototype (compiling, runs CRUD with bound parameters):
`scratchpad/proto/db/{db.goose,shim.c,db.build}` from the v0.3 session.

**Packaging.** SQLite must stay opt-in: the core framework does not link `libsqlite3`. Ship it as a
second package directory `db/` (`db/goose_web_db.goose` + `db/goose_web_db.build` with
`c_sources = ["sqlite_shim.c"]; c_libs = ["sqlite3"];`) importable as
`import goose_web_db from "../../db";`. If the compiler only honours the root program's `.build`,
document that apps add `c_libs = ["sqlite3"]` to their own sidecar and keep the shim in the package.

**C boundary.** C keeps fixed tables of `sqlite3*` and `sqlite3_stmt*` and hands Goose integer
handles (Goose cannot hold C pointers in data). Text crosses as `{data,len}` slices (bound with
explicit length + `SQLITE_TRANSIENT`); results are copied into caller slices after asking for their
length (builders `u8[>..]&` are not available to separately compiled sidecar C). No SQL text is
ever built from values: values are always bound. Identifiers come only from `fields<T>` names and
registered table names, validated as `[A-Za-z_][A-Za-z0-9_]*`.

**API.**

```goose
struct Todo { id: i64, title: u8[..200], completed: bool }
fn web::db_table(v: Todo&) -> const u8[:] { "todos" }        // required registration
// optional: fn web::db_primary(v: Todo&) -> const u8[:] { "id" }  (default "id")

var db = default<web::Db>();
guard web::db_open(db, "build/app.db") else { abort(web::db_error(db)); }   // WAL + busy_timeout set
web::migrate(db, ["ALTER TABLE todos ADD COLUMN due INTEGER NOT NULL DEFAULT 0"]);  // schema_version table
web::create_table<Todo>(db);                       // CREATE TABLE IF NOT EXISTS from fields
let id, ok = web::insert(db, item);                // i64 primary == 0 → INTEGER PRIMARY KEY autoincrement; returns rowid
web::update(db, item);                             // by primary key; false + error if no row
web::remove<Todo>(db, id);
let t, found = web::find<Todo>(db, id);
web::select<Todo>(db, web::query().where_eq("completed", false).order_by("id", true).limit(20)) { row => ... };
let n = web::count<Todo>(db, web::query().where_eq("completed", true));
let ok2 = web::transaction(db) { web::insert(db, a).1 && web::update(db, b) };   // block value decides COMMIT/ROLLBACK
```

- Types: all int widths and bool → INTEGER (range-checked on read), f32/f64 → REAL, `u8[..N]` → TEXT
  (read truncation is an error, not silent), nested structs and limited arrays → TEXT holding JSON via
  `json_encode`/`json_decode` (same registration idiom as the codec).
- `Query` is a fixed-size value: up to 8 conditions (`where_eq/ne/lt/le/gt/ge/like`, AND-joined),
  values held in a fixed-mode enum `SqlValue { Int, Real, Text { v: u8[..256] }, Null }`; column names
  validated against `fields<T>` at run time (unknown column → `abort` with the name: programmer error).
- Errors: every call returns bool; `web::db_error(db)` gives the last SQLite message (bounded copy).
- `transaction` takes a block whose **value** is the commit decision; a block `return` would skip
  COMMIT/ROLLBACK, so it is documented as forbidden inside transactions (tests prove rollback on false).
- Blocking: calls run on the reactor thread. Document WAL, short queries, and indexes; worker-thread
  offload is future work (only flat values may cross Goose thread queues).
- Example: `examples/sqlite-todos/` (a compact Todo API persisted in SQLite, OpenAPI-annotated), plus
  unit tests on `:memory:` and an integration test over sockets with restart persistence.

### Implementation notes (v0.3 OpenAPI, as built)

- Goose requires a resizable field to be the last field of its struct, so the describe state
  (`OpenApiState` in `src/app/openapi_state.goose`) keeps its fixed-capacity fragments first and its
  growable text buffer last.
- The routes block captures `c`, so Goose refuses to shrink `c` (`clear()`) while the block is live.
  Describe state is therefore changed only by building a local copy and assigning it back whole.
- The describe pass is entered from `routes()` when the request is for the document or the docs page
  (`oas_kind`). Annotations check `c.pass == PASS_DESCRIBE` first, so they are free elsewhere.
- Path parameters are documented as strings, as designed; query parameters are all optional.
- Still open: per-field constraints beyond the integer width (for example `limit` 1..8), per-status
  error codes such as 409 and 503, and `$ref` reuse. `examples/basic/openapi.yaml` is kept for those.

**Implementation notes (v0.4, as built).**

- Packaging: `db/` is a local package with its own sidecar. The compiler builds a package's sidecar
  `c_sources` and `c_libs` when the package is imported, so the core framework stays free of
  `libsqlite3`. Verified with a probe package outside the repo.
- `web::find` is `web::find_row`. An unqualified `find` in namespace `web` hides the stdlib `find`
  that the core calls, which broke the framework in any program importing the package.
- Builders are functions, `web::where_eq(web::query(), ...)`: a UFCS chain across namespaces is not resolved.
- `order_by(q, column, descending)` takes an explicit `descending` flag.
- `select` and `transaction` take their block as the trailing function value; `transaction` is
  `BEGIN` plus the block's bool. `migrate` takes a `const u8[:][:]` step list.
- Nested struct fields need the codec pair plus `sql_put_value`/`sql_read_value` (JSON route), not
  just the codec pair, because Goose cannot tell a struct from a limited array in the generic path.
- Primary keys must be `i64`, so `remove`, `update` and `find_row` take an `i64` key.
- NULL: every column is `NOT NULL`; a NULL read is an error. Only the zero key on insert binds NULL.

## v0.5 design: server-sent events

Goal: push events to browsers (`EventSource`) and other long-lived readers without closures. The
reactor stays synchronous: a handler upgrades its connection, and application code publishes events
by channel from ticks, event drains and handlers. No callback is stored per connection.

**Upgrade.** `c.sse(channel: i32) -> bool` sets `Response.sse` and `Response.sse_channel` and makes the
response a stream head: `200`, `Content-Type: text/event-stream`, `Cache-Control: no-cache`,
`Transfer-Encoding: chunked`, plus headers set with `c.set` beforehand. It returns false, changing
nothing, when a response was already written. The reactor performs the upgrade after the handler
returns, so the handler's `return` ends the route. Middleware still runs after the handler.

- HTTP/1.1 only. HTTP/1.0 and HEAD requests asking for a stream get `400` and a close. Close-delimited
  1.0 streams would need unframed fan-out, which this design avoids.
- `keep_alive` does not apply to streams. A stream is never reused for a second request, and any bytes
  the client sends after the request are discarded.
- Refused with `503` and close when stopping, when shutdown was requested, or when `max_sse_clients`
  streams are already open. The effective limit is `min(max_sse_clients, max_clients)`.
- A stream does not count as a completed request, so `max_requests` ignores it.

**Connection state.** A streaming connection keeps its chunk chain in the shared pool, the same
mechanism responses use. Its `deadline` is the next heartbeat, not a read or idle timeout, so streams
are exempt from `read_timeout_ms` and `idle_timeout_ms`. Every `sse_heartbeat_ms` (default 15000) the
reactor queues the chunk `: ping\n\n`.

**Publish.** `web::sse_publish(control, channel, event: const u8[:], data: const u8[:]) -> i64`
formats one SSE message (`event:` line when the name is non-empty, one `data:` line per line of
`data`, with CR, LF and CRLF all treated as line breaks, then a blank line), frames it as one chunk,
and returns the number of streams on that channel when the message was accepted. Return values:
`-1` refused (event name with CR or LF or longer than `MAX_SSE_EVENT_BYTES`, data too large, framed
message over `sse_max_queued_bytes` or `MAX_SSE_MESSAGE_BYTES`, or the outbox full), `0` when not
running, stopping, or no stream subscribes to the channel.

Connection chains belong to the reactor and the pool is local to `serve_config`, so application code
cannot write into them directly. Instead, publish appends the framed chunk to a bounded outbox in
`ServerControl`, and the reactor fans it out at the start of each loop iteration, before it polls.
Fan-out is in publish order, so each stream sees its channel's events in order. A publish made during
the handler phase reaches the sockets before the next poll.

**Slow consumers.** A stream's unsent bytes are its queued bytes. Fan-out and heartbeats drop the
stream (close, `sse_dropped += 1`) when the queue would pass `sse_max_queued_bytes` (default 256 KiB)
or the pool has no chunks left. Dropping never blocks the reactor and never affects other streams.

**Shutdown.** When stopping begins, the reactor first fans out pending messages, then queues
`event: close` plus the terminating chunk `0\r\n\r\n` on every stream. A stream closes once that
data is flushed. The grace deadline still applies, so an unread stream is force-closed at the end.

**Stats.** `ServerStats` adds `sse_active` (open streams), `sse_sent` (events queued to streams),
and `sse_dropped` (streams closed for slowness or pool exhaustion).

**Bounds.** Per stream: `sse_max_queued_bytes` plus a 128-byte reserve for the close event. Total
pool: `max_pool_bytes`. Outbox: 256 KiB and 64 message records, drained every iteration. One message:
at most 64 KiB of input data. Heartbeat and close framing use fixed bytes. Streams never allocate per
event.

**Deviations from the initial brief.** `sse_publish` returns after staging into the outbox, not
after writing into connection chunks. The fan-out therefore happens one loop iteration later, which
is at most one poll interval. `max_sse_clients` is clamped to `max_clients` at use instead of being
validated against it, so existing configurations with a small `max_clients` stay valid.

## v0.6 change: per-request state moved out of `Ctx`

Problem: `Ctx` embedded the route table (64 routes, about 43 KB), the session store (about 5 KB),
the OpenAPI pending fragments (about 12 KB) and its operation index. `new_ctx` zeroed all of it on every
request, and `c.routes()` built a second table and copied it. Apps that used none of those features
still paid for them.

**Implementation notes (v0.6, as built).**

- `AppScratch` (`src/app/context.goose`) holds `table`, `session_state`, `csrf_state` and `oas`. It is
  fixed-size. `run`/`run_with` keep one in the `app_scratch` global, which is safe because handlers run
  one at a time on the reactor thread. Tests that hold several `Ctx` at once declare their own.
- `Ctx` holds references to those parts (`table: Router&`, `session_state: SessionState&`, and so on), so
  field access such as `c.session_state.count` and `c.oas.config` is unchanged. Building a `Ctx` copies
  only the request view, the response reference and a few small fields.
- `new_ctx(request, response, scratch)` takes the scratch as its third argument. This is the one
  signature change, and it affects only code that builds `Ctx` by hand (the unit tests).
- `scratch_reset` clears only the counts and flags a request reads first. Route entries, session entries
  and OpenAPI fragments are not cleared, because every read is bounded by a count that was reset.
- Goose refuses to shrink a buffer while a caller-supplied request may hold a slice into it. The OpenAPI
  describe text is therefore a growable field of `Ctx` (its last field), and it starts empty for each
  request. The fixed-size OpenAPI state stays in the scratch.
- `ServerControl` stays fixed-size. Applications build it with `default<web::ServerControl>()` for
  `run_with`, so making its outbox growable would be a public API change. Its 256 KiB outbox is zeroed
  once at startup, which is the main remaining startup RSS cost.
