# API contracts

Public names such as `web::HTTP_OK`, `web::METHOD_GET`, and `web::CONTENT_TYPE_JSON`
are available through the package import. See the [constants reference](constants.md)
for fixed limits, configurable defaults, headers, and lifecycle identifiers.

## HTTP and headers

`Request` contains read-only `method`, `target`, `body`, and `raw_headers` views.
`request_header(request, name)` looks up the first case-insensitive header and returns
an empty view when missing. Empty and absent values are not distinguished.

`response()` returns status 200, text/plain UTF-8, an empty body, and no extra headers.
`set_header(response, name, value)` replaces case-insensitively or inserts; false leaves
state unchanged. Capacity is 16 headers, names 64 bytes, values 256 bytes. Invalid names,
controls, framing headers, and content-type overrides are rejected; use `content_type`
for that field. Serialization also validates direct struct mutations and rejects duplicates.
The body is a growable buffer, read with `body_of(response)` (a `const u8[:]` view) and `body_len(response)`.
Writes are `set_body(response, bytes) -> bool` (replaces the body) and `append_body(response, bytes) -> bool`
(extends it). Each returns false, leaving the response unchanged, when the write would exceed
`response.max_body`. The runtime sets `max_body` from `config.max_response_bytes` (default 1 MiB, ceiling
`MAX_RESPONSE_BODY_BYTES` = 16 MiB); an over-limit body becomes a complete 500 `response_too_large` JSON
error. Error envelopes may use `MAX_ERROR_BODY_BYTES` (64 KiB) beyond `max_body`, so a refused write can
still be replaced by its 500. `drop_body(response)` discards the body. Writes only append during a request
(the buffer never shrinks while a handler may hold views); the runtime clears it after the response is
serialized, and keeps its capacity for the next request, so memory tracks the largest response served
(bounded by the ceiling). `max_body` counts every byte the buffer holds, including bodies that were replaced,
so the bound holds however many writes a handler makes.

`append_header(response, name, value)` is `set_header` except for `Set-Cookie`, which may repeat:
each call adds one line (RFC 6265). Serialization allows repeated `Set-Cookie` and still rejects
any other repeated name, so `set_header` on `Set-Cookie` replaces the earlier line.

HTTP/1.0 and HTTP/1.1 origin-form requests use Content-Length bodies. Connections persist
(see the HTTP profile below); `Connection` is read as a case-insensitive token list.
Targets follow strict ASCII URI syntax with validated percent escapes; raw Unicode
and fragments are rejected. Host values must match the supported reg-name/bracketed
IPv6 profile, with optional numeric port. Only SP/HTAB are trimmed around field values.
Duplicate Host/Content-Length, invalid header names/control bytes, and ambiguous framing
return 400. Unsupported transfer encoding returns 501; Expect returns 417. HEAD sends
no body but retains the selected representation's length. Parser errors remain plain
text and close the connection; application errors use the JSON helper below. These are bounded experimental protocol rules, not a claim
of complete HTTP conformance.

## Routes and query values

```goose
var routes = web::router();
assert(web::add_route(routes, web::METHOD_GET, "/users/:id", 1));
let selected = web::match_route(routes, request.method, request.target);
// selected.status: 200, 404, or 405
// selected.handler_id selects your named handler; selected.allow supplies Allow.
let id = web::path_param(selected, "id");
```

The table owns 64 descriptors, methods up to 16 bytes, patterns up to 512 bytes, and
up to 16 named parameters. Failed registration leaves the table unchanged. Equivalent
same-method patterns are rejected. Registration also reserves a 256-byte Allow budget.
Static segments win before method selection; a wrong method on `/users/new` cannot
fall through to `/users/:id`. Explicit HEAD wins; otherwise GET handles HEAD.
Path case, trailing slashes, repeated slashes, and encoded bytes are exact; path
parameters consume one nonempty segment and are not percent-decoded.

`target_path(target)` and `target_query(target)` split on the first `?`.
`query_value(target, key)` returns owned `value` and `status`: 0 missing, 200 present
(including empty), 400 invalid escape, 413 decoded field over 1024 bytes. It decodes
percent escapes and `+` as space, preserves binary bytes, returns the first duplicate,
and validates all query fields even after finding the requested key. Callers must
check the status before using the value. No Unicode normalization is applied.

## Middleware and application errors

`valid_utf8(text)` checks that bytes form valid UTF-8, rejecting truncated, overlong,
surrogate, and out-of-range encodings. It does not reject control characters;
the consuming format or application applies that policy. The JSON codec checks UTF-8
before it parses a request body.

`pipeline(request, response, before, handler, after)` calls before first. Its boolean
result controls whether handler runs. After always runs when callbacks return normally,
including on rejection. Nest pipelines through a named handler for additional layers;
after-callbacks unwind from inner to outer. Do not use nonlocal returns to exit the
entire caller from a callback when relying on later callbacks.

`application_error(response, status, code, message)` emits:

```json
{"error":{"code":"not_found","message":"Route not found"}}
```

It returns true if the full error fits. Invalid status outside 400..599, malformed
UTF-8, or escaped data over the body limit produces a complete 500 `internal_error`
response and returns false. Existing headers survive. Inputs may borrow the response's
old fields; encoding completes before those fields change. Controls, quotes, and
backslashes are escaped, and valid multibyte UTF-8 is preserved.

## Events

`event_bus<T>()`, `subscribe(bus, topic, once=false)`, `unsubscribe(bus, id)`,
`dispatch(bus, topic, args)`, and `drain(bus, callback)` form the native event API.
The callback receives subscription ID and `Event<T> { topic, args }`.

- Arguments are owned fixed-size values; use structs for multiple arguments.
- 64 active listeners; subscribe returns 0 when full. IDs are not reused.
- 256 FIFO queued events; dispatch returns false when full.
- Listeners run in subscription order; unsubscribe takes effect immediately.
- One-shot listeners are removed before invocation. New listeners start with the next event.
- Drain processes only its initial batch; recursive drain returns 0. Do not replace the
  bus or exit the enclosing function nonlocally during drain.
- The bus belongs to its reactor thread. No cross-thread shared mutable state.

The example retains the requested 503 response on queue overflow. Applications must
choose this policy before side effects: returning 503 cannot undo completed work.

## Runtime configuration and lifecycle

`server_config()` provides these defaults:

| Field | Default | Valid range / meaning |
| --- | --- | --- |
| port | 8080 | 1..65535 |
| public_bind | false | loopback; true explicitly binds IPv4 wildcard |
| max_clients | 64 | 1..64 |
| max_request_bytes | 8192 | 1..8192, includes headers and body |
| max_response_bytes | 1048576 | 1..16777216, response body limit; larger bodies become a 500 |
| max_pool_bytes | 8388608 | `max_response_bytes` + 8192 .. 67108864, bytes of serialized responses in flight; a response that does not fit gets a 503 and the connection closes |
| read_timeout_ms | 5000 | 1..86400000, time to receive each request once its first byte arrives |
| write_timeout_ms | 5000 | 1..86400000, total write phase per response |
| idle_timeout_ms | 5000 | 1..86400000, wait for the next request's first byte on a persistent connection |
| poll_timeout_ms | 10 | 1..1000, capped by nearest active deadline |
| shutdown_grace_ms | 5000 | 0..86400000 |
| max_requests | 0 | nonnegative; 0 unlimited; server-wide completed responses before shutdown |
| max_requests_per_connection | 100 | 0..1000000; 0 unlimited; the last allowed response says `Connection: close` |
| keep_alive | true | false answers every request with `Connection: close` |
| handle_signals | false | opt-in process-wide SIGINT/SIGTERM ownership |

`validate_server_config(config)` rejects invalid combinations before opening a socket.
`serve_config(config, control, handler, tick, lifecycle)` returns false on invalid
configuration, bind/signal setup failure, or fatal poll failure. Handler receives
request/response, tick receives no arguments, and lifecycle receives stage/stats.
All callbacks are synchronous. Tick can capture `control` and call `request_shutdown(control)`.

Lifecycle stages are `SERVER_STARTED`, `SERVER_STOPPING`, and `SERVER_STOPPED`.
Shutdown closes the listener and drains already accepted clients until the grace
period expires. Idle persistent connections close at once; a request in flight finishes
with `Connection: close` and then the socket closes, and pipelined requests not yet
started are not run. `max_requests` triggers this drain; accepted work may take completed
responses past the threshold. `shutdown_requested` remains latched: clear it, or use
a fresh control, before restarting. Stats reset on a successful new run.

`control.stats` reports accepted (including capacity rejections), active, completed
(fully transmitted responses, including HTTP errors), rejected (capacity), timeouts,
forced_closes (grace/fatal cleanup), bytes_read, bytes_written, and reused. Protocol errors
are not capacity rejections. Idle timeout closes the socket without a response.
`reused` counts responses served on a connection that had already completed one.

Signals are optional for embedding; the basic example enables them. Only one
signal-owning server may run in the process, and previous handlers are restored on
normal exit. Multithreaded embedders should manage signals externally. The legacy
`serve(port, max_requests, handler, tick)` wrapper keeps loopback defaults.

## JSON codec

`src/json/codec.goose` maps structs to compact JSON objects and back, from `fields<T>`.
Field names are emitted as declared, in declaration order, with no whitespace.

- `json_encode(out, value) -> bool` appends to a growable `u8[>..]`. `value` is a struct (by
  value), or a scalar or literal string at top level. Strings must be valid UTF-8; otherwise
  it returns false and `out` is unchanged. Bytes are escaped per the stdlib writer.
- `json_decode<T>(text) -> T, DecodeResult` is strict: unknown keys, duplicate keys, wrong
  types, out-of-range integers, overlong strings, full arrays, invalid UTF-8 and trailing
  input are errors. Missing keys keep the declared defaults (`T { .. }`).
- `DecodeResult { ok, syntax, error: u8[..128], field: u8[..64], present: u64 }`. `syntax`
  is true when the text is not JSON at all (map to 400); other errors are schema problems
  (map to 422). `field` is the key where the first error occurred. `present` bit i is set
  for top-level field i in declaration order; nested objects do not set bits.
- `has<T>(result, name) -> bool` reports whether top-level field `name` was present.

| Type | Encodes as | Decodes from |
|---|---|---|
| `i8`..`i64`, `u8`..`u32` | number | integer, within the width |
| `u64` | number | integer up to `i64` max; above that is rejected |
| `f32`, `f64` | number | any number; NaN and infinities encode as `null` |
| `bool` | `true` or `false` | `true` or `false` |
| `u8[..N]`, `u8[>..]`, `u8[]`, `const u8[:]` | string | string, into `u8[..N]` only |
| `T[..N]` (limited) | array | array, at most N elements |
| `T[N]`, `T[>..]`, slices | array | not decodable (no capacity: see below) |
| structs | object | object, via registration (below) |

A `u8` array is always a string, never an array of numbers. `f32` encodes its f64 value, so
`0.1f32` writes `0.10000000149011612`. Structs with more than 64 fields abort at decode.

Nested structs need one overload per direction in namespace `web`, because Goose cannot
tell a struct from a limited string in the generic path:

```goose
fn web::json_put_value(out: u8[>..]&, v: Inner&) -> bool { return web::json_put_fields(out, v); }
fn web::json_read_value(d: web::JsonDecoder&, out: Inner&) { web::json_read_fields(d, out); }
```

Decoding is limited to limited arrays and strings, because the decoder needs a capacity to
bound untrusted input; fixed and grow arrays can be encoded but not decoded.

Decoding runs in two passes: a syntax pass over the whole text, then the typed pass. So
errors found in the second pass are never syntax errors.

## Application API

The app layer (`src/app/`) is built only on the calls above. An app is one function over
`web::Ctx&`, served with `web::run(config) { c => app(c) }`. Application code in the global
namespace calls these through `c.name(...)` (UFCS); `src/app/dsl.goose` forwards each name
there. Inside namespace `web` call `web::name(c, ...)` directly.

### Ctx accessors

| Call | Meaning |
| --- | --- |
| `c.method()`, `c.path()`, `c.target()`, `c.header(name)` | request views |
| `c.param(name)`, `c.param_int(name)` | path parameter; `param_int` writes 422 `invalid_param` on failure |
| `c.query(key)`, `c.query_int(key, default)` | query value; `query_int` writes 400 `invalid_query` on failure |
| `c.status(code)` | sets the status and returns `Ctx&` for chaining |
| `c.set(name, value)` | response header (asserts on an invalid header) |
| `c.text(s)`, `c.html(s)`, `c.json_raw(s)` | content type and body; over capacity → 500 `response_too_large` |
| `c.json(value)`, `c.json_list(items)` | JSON responses (below) |
| `c.body<T>()` (see below) | request body; written as `body<T>(c)` |
| `c.no_content()`, `c.redirect(location, code)`, `c.fail(status, code, message)` | responses |
| `c.done()` | true once a response was written; middleware can short-circuit on it |

`c.body<T>()` is spelled `body<T>(c)`: the parser does not accept explicit type arguments on a
UFCS call. `c.request_id` is a `Ctx` field, so the middleware is called as `request_id(c) { }`.

### Routing DSL

`c.routes() { ... }` runs its block twice:

1. *Match pass.* Each `c.get/post/put/patch/delete/head/options/any(pattern) { }` records
   whether `prefix + pattern` matches the path. Route bodies do not run.
2. The best route is selected with the rules in `router.goose`. No path match → 404
   `not_found`. A path match without the method → 405 `method_not_allowed` with `Allow`.
3. *Dispatch pass.* The block runs again. Only the selected route's body runs, with path
   parameters bound.

Consequences:

- Code in `c.routes() { }` outside a route body runs twice. Keep it declarative: route calls,
  `c.group(prefix) { }`, and functions that declare routes.
- Routes are matched by declaration order, so both passes must declare the same routes. Do not
  branch on mutable state between passes.
- `return` inside a route body leaves the enclosing named function, which ends that route.
- Invalid patterns abort with the pattern in the message.

### Middleware

Middleware is `fn name<Next>(c: Ctx&, ...) { before; Next(); after; }`. Not calling `Next()`
short-circuits. Nesting gives the order: the outer middleware's `before` runs first, and its
`after` runs last.

| Call | Behavior |
| --- | --- |
| `request_id(c) { }` | next value of a process-global counter, stored in `c.request_id` and sent as `X-Request-ID` |
| `logger(c) { }` | after `Next`, prints one line: `METHOD path status bytes`; control bytes are masked |
| `cors(c, origin = "*") { }` | sets `Access-Control-Allow-Origin` (plus `Vary: Origin` for a non-wildcard origin). A preflight (OPTIONS with `Access-Control-Request-Method`) gets 204 with Allow-Methods, Allow-Headers (echoes the request's headers when valid, else `Content-Type`) and `Max-Age: 600`, and `Next` is not called |
| `require_json(c) { }` | 415 `unsupported_media_type` unless the media type is `application/json` (parameters ignored, case-insensitive). It applies to every request in its block, so wrap body-carrying routes |

### JSON responses and request bodies

- `c.json(value)` encodes a struct or scalar, passed by value, and keeps the status already set
  by `c.status()` (default 200). It sends `application/json`. Failures: over capacity → 500
  `response_too_large`; invalid UTF-8 → 500 `encode_error`.
- `c.json_list(items)` encodes an array or slice as a JSON array. Use it for arrays and slices;
  `c.json` on an array does not compile. A `u8` slice is text.
- `body<T>(c) -> T, bool` decodes the body strictly. `body_result<T>(c) -> T, DecodeResult`
  also returns the decoder result (`has<T>(result, "field")` for PATCH). On failure the error
  response is already written:

| Failure | Status | Code |
| --- | --- | --- |
| media type is not `application/json` | 415 | `unsupported_media_type` |
| empty body | 400 | `invalid_json` |
| not JSON, or invalid UTF-8 | 400 | `invalid_json`, message "Malformed JSON: ..." |
| schema error | 422 | `invalid_payload`, message "field: error" |

Nested structs must be registered in namespace `web`, once for encoding (`c.json_list`) and once
for decoding (`body<T>`):

```goose
fn web::json_put_value(out: u8[>..]&, v: Item&) -> bool { return web::json_put_fields(out, v); }
fn web::json_read_value(d: web::JsonDecoder&, out: Item&) { web::json_read_fields(d, out); }
```

### Typed query strings

`query<T>(c) -> T, bool` binds the decoded query into struct `T` by field name, using the same
reflection as `body<T>`. `query_result<T>(c) -> T, DecodeResult` returns the decoder result
instead (`has<T>(result, "field")` tells whether a key was present).

```goose
struct Search { limit: i32 = 10, q: u8[..32] = "", active: bool = false, score: f64 = 0.0 }

c.get("/search") {
    let s, ok = query<Search>(c);     // called as a plain function, not c.query<Search>()
    guard ok else { return; }
    c.json(s);
};
```

Rules, matching `body<T>`:

- Missing keys keep the declared default. Unknown keys and duplicate keys are errors.
- Keys and values are decoded with `query_decode` (percent escapes, `+` as space). Empty pairs
  (`a=1&&b=2`, a trailing `&`) are skipped.
- Field types: `i8`..`i64`, `u8`..`u64`, `bool`, `f32`, `f64`, `u8[..N]`. Integers are canonical
  decimal: optional leading `-` (signed types only), no `+`, no leading zeros, range-checked.
  `bool` accepts `true`, `false`, `1`, `0`. Strings must be valid UTF-8 and fit `N` bytes.
- Failure writes 400 `invalid_query` with the message `field: reason`, for example
  `limit: integer out of range`, `q: string too long`, `zzz: unknown key`, or
  `limit: duplicate query parameter`. A key that is not valid UTF-8 gets a fixed message.
- Other struct field types are not supported.

### Cookies

`c.cookie(name) -> const u8[:]` returns the value of the first cookie with that exact name in the
request's `Cookie` header, or `""` when absent. Pairs are split on `;`, surrounding SP/HTAB is
trimmed, a DQUOTE-wrapped value is unwrapped, and a pair without `=` is ignored. Only the first
`Cookie` header is read. Values come back as sent, so an invalid cookie octet is visible to the caller.

`c.set_cookie(name, value, opts = CookieOptions { .. }) -> bool` appends one `Set-Cookie` line.
Each call adds a header, so several calls produce several `Set-Cookie` lines (see
`append_header` under HTTP and headers). It returns `false`, and changes nothing, when:

- `name` is not an RFC 7230 token, or `value` has a byte outside RFC 6265 cookie-octet
  (spaces, `"`, `,`, `;`, `\`, controls and non-ASCII are refused);
- `path` is non-empty and not an absolute path, or contains a control or `;` (an empty `path`
  omits the attribute);
- `same_site` is not `Strict`, `Lax`, `None` or empty (matched case-insensitively), or it is
  `None` without `secure`;
- the line does not fit the 256-byte header value capacity or the header count is full.

```goose
struct CookieOptions {
    path: u8[..64] = "/",
    max_age: i64 = -1,        // negative omits Max-Age; 0 asks the client to delete now
    http_only: bool = true,
    secure: bool = false,
    same_site: u8[..8] = "Lax",    // "" omits SameSite
}

c.post("/login") {
    let ok = c.set_cookie("session", token, web::CookieOptions { max_age: 3600, secure: true, same_site: "Strict" });
    guard ok else { return; }
    c.no_content();
};
```

Struct literals name fields in declaration order (`path`, `max_age`, `http_only`, `secure`,
`same_site`). Leave fields out to keep their defaults.

### Static files

`c.static_files(url_prefix, directory) { next }` is middleware. It serves GET and HEAD requests under
`url_prefix/` from `directory`, and otherwise calls `next` (the routes that follow it). Put it
inside `request_id`, `logger`, and `cors` so the headers and log lines apply to file responses.

```goose
c.static_files("/static", "public") {
    c.routes() { ... };
};
```

It was chosen over a route kind because the router has no wildcard segment, and a middleware keeps
the matching rule in one place. The consequences are part of the contract:

- Any GET or HEAD under the prefix is owned by the middleware. A missing file answers 404
  `not_found` without calling `next`, so GET routes under the same prefix are shadowed.
  Other methods under the prefix fall through to the routes.
- `url_prefix` must start with `/`; a trailing `/` is ignored. `directory` is trusted configuration
  and must be nonempty. Its relative path is resolved from the process working directory.

Mapping and refusals (the path after the prefix is percent-decoded and checked segment by segment):

| Request | Result |
| --- | --- |
| `/static/` or a directory such as `/static/docs` | its `index.html`, or 404 when there is none |
| `/static/a%20b.txt` | file `a b.txt` |
| `..` or `.` segment, raw or encoded (`%2e%2e`) | 400 `invalid_path` |
| encoded `/`, `\`, NUL or a control byte (`%2F`, `%5C`, `%00`, `%0a`), raw `\` | 400 `invalid_path` |
| empty segment (`//`, leading `/`), truncated or invalid `%` escape | 400 `invalid_path` |
| a segment starting with `.` (dotfiles, `.git`) | 404 `not_found` |
| missing file | 404 `not_found` |

Content-Type comes from the extension, case-insensitively: `html`/`htm`, `css`, `js`/`mjs`,
`json`, `svg`, `png`, `jpg`/`jpeg`, `gif`, `ico`, `txt`, `wasm`. Anything else, including no
extension, is `application/octet-stream`. Served files also carry `X-Content-Type-Options: nosniff`.
Do not serve untrusted uploads from the directory: an `svg` or `html` file runs with the
application's origin.

Size and blocking: the file is read on the reactor thread, so no request is served while that
happens. Each read is bounded before any byte of the file is copied:

1. `stat` reports the regular file's size. A size over the response's `max_body` (the configured
   `max_response_bytes`, default 1 MiB) is refused with 500 `file_too_large` and the file is never read.
2. Otherwise the reader asks for `size + 1` bytes (the spare byte detects a file that changed
   during the read). The count must equal the stat size; any other count is a failed read.
3. A missing entry, directory, FIFO or other non-regular file is 404 `not_found`. A file that
   exists but cannot be opened or read, or that changed size during the read, is 500
   `file_read_failed`. Before this change these cases answered 404.

Keep served trees small and trusted, or serve
large assets elsewhere. Symbolic links inside the directory are followed.

The framework reads files and the environment through `src/sys/`, not the `os` stdlib. Importing
`os` into framework code made its global names (`read_file`, `is_dir`, `clock_ns`, ...) ambiguous
for every application that imported `goose_web`. Applications may use `os` freely.

## Command-line and environment configuration

`web::config_from_args(argv) -> ServerConfig, bool, u8[>..]` builds a configuration from `args()`
(argv[0] is the program name). On failure the bool is false and the message says what was wrong.

| Argument | Meaning |
| --- | --- |
| `[port]` | a bare first argument is the port (the original examples' form) |
| `--port N`, `--port=N` | 1..65535 |
| `--host public` or `--host loopback` | `public_bind` true (all IPv4) or false (127.0.0.1) |
| `--max-clients N` | 1..`MAX_CLIENTS` |
| `--max-requests N` | 0 unlimited; otherwise stop after N completed responses |

Other arguments are errors: unknown options, a missing value, and a second bare argument. An
application that takes its own positional arguments passes only the prefix it owns; the basic
example passes `argv[..2]` and reads max-responses and the data file itself. Ranges are checked
by `validate_server_config`.

`web::config_from_env() -> ServerConfig, bool, u8[>..]` reads `GOOSE_WEB_PORT` (the `--port` rule)
and `GOOSE_WEB_PUBLIC` (`1` or `true` for public, `0` or `false` for loopback). Unset and empty
variables keep the defaults. A value longer than 256 bytes is invalid.

```goose
fn main() {
    let config, ok, error = web::config_from_args(args());
    if !ok { abort(error); }
    let started = web::run(config) { c => app(c) };
    if !started { abort("server failed"); }
}
```

Blocking: each file is read whole with `read_file` on the reactor thread, and no request is
served while that happens. The `os` stdlib has no file size query, so the read itself is not
bounded by the response capacity. The response is: a body over `MAX_RESPONSE_BODY_BYTES` becomes
500 `response_too_large`. Keep served trees small and trusted, or serve large assets elsewhere.
Symbolic links inside the directory are followed.

### OpenAPI

`web::openapi(c, info) { c.routes() { ... } }` serves an OpenAPI 3.1 document at `info.json_path`
(default `/openapi.json`) and a Swagger UI page at `info.docs_path` (default `/docs`, loading a pinned
`swagger-ui-dist` build from cdn.jsdelivr.net). The document is generated from the same routes block:
the routes run once more in a *describe* pass in which no route body runs. The document paths are
answered only when `openapi` wraps the routes; otherwise they are ordinary 404s.

```goose
web::openapi(c, web::OpenApiInfo { title: "Todo API", version: "1.0.0", description: "..." }) {
    c.routes() {
        web::summary(c, "Create a todo");
        web::accepts<TodoInput>(c);                  // requestBody (application/json)
        web::returns<Todo>(c, web::HTTP_CREATED);    // response schema for one status
        c.post("/todos") { ... };
        web::query_params<ListParams>(c);            // query parameters from struct fields
        web::returns_list<Todo>(c, web::HTTP_OK);    // array response
        c.get("/todos") { ... };
    };
};
```

Annotations are plain calls placed before the route they describe. Outside the describe pass they do
nothing, so they cost normal requests nothing and may be used in any app. They attach to the next
route only:

| Call | Documents |
| --- | --- |
| `web::summary(c, text)` | operation summary |
| `web::tag(c, name)` | tag; default is the first segment of the enclosing `c.group` prefix |
| `web::accepts<T>(c)` | `requestBody` (`application/json`, required) from struct `T` |
| `web::returns<T>(c, status)` | response `status` with the schema of struct `T` |
| `web::returns_list<T>(c, status)` | response with an array of `T` |
| `web::returns_empty(c, status)` | response with no body (for example 204) |
| `web::query_params<T>(c)` | optional query parameters, one per field of `T` |

Generic calls are written in the non-UFCS form (`web::accepts<T>(c)`), since UFCS takes no explicit
type arguments (as with `body<T>(c)`).

Schemas are inline (no `$ref`), built from `fields<T>`:

- integers are `integer` with `minimum`/`maximum` for their width (`u64` up to `i64` max, as the
  codec accepts); `f32`/`f64` are `number`; `bool` is `boolean`.
- `u8[..N]` text is `string` with `maxLength: N`; other limited arrays are `array` with `maxItems: N`.
- A struct nested in another struct needs a registration in namespace `web`, next to its JSON one:

```goose
fn web::json_schema_value(out: u8[>..]&, v: Inner&) { web::json_schema_fields(out, v); }
```

- Every field is `required` unless the struct lists its optional fields with a registered hook (a
  comma list; Goose cannot see declared defaults, so this is explicit):

```goose
fn web::optional_fields(v: TodoInput&) -> const u8[:] { return "completed"; }
```

Each operation also documents the framework's error envelope (`{"error":{"code","message"}}`) for
400, 404, 405 (with `Allow`), 415, 422 and 500, unless the route declares that status itself.
Path parameters `:id` become `{id}` and are documented as required strings.

Limits, stated so they are not a surprise:

- Constraints beyond the width (for example `limit` is 1..8) are not expressible; write them in the
  `summary` or in the docs.
- One schema per request body. PUT and PATCH therefore use separate documentation structs when their
  required fields differ from POST's.
- `any()` routes have no OpenAPI method and are not documented.
- Annotation fragments are bounded (4 KiB per request body, responses or query parameters). Overflow
  aborts while `/openapi.json` is generated, which is a programmer error; the document itself must
  fit the response cap (`MAX_RESPONSE_BODY_BYTES`, 64 KiB today).
- The document is compact JSON with no whitespace and is regenerated per request.
