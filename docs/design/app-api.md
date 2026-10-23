# Application API (v0.2 design)

Status: accepted design, being implemented. The low-level API in [api.md](../api.md)
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
    c.get("/") { c.json(todos) };                      // arrays of structs encode too
    c.post("/") {
        let input, ok = c.body<TodoIn>();              // 415 / 400 / 422 written for you
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
    web::request_id(c) { web::logger(c) { web::cors(c) {
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

One value per request, owned by the server loop for the duration of the handler.

```goose
struct Ctx {
    request: Request,          // borrowed views, valid only during the handler
    response: Response,        // owned; serialized after the app returns
    // routing state (private by convention: names start with route_)
    // path params of the selected route (bounded, MAX_PATH_PARAMS)
    // user slot: a small fixed `locals` area, e.g. request_id: i64
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
