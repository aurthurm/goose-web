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
The response body capacity is 8192 bytes.

HTTP/1.1 origin-form requests use Content-Length bodies and one response per connection.
Targets follow strict ASCII URI syntax with validated percent escapes; raw Unicode
and fragments are rejected. Host values must match the supported reg-name/bracketed
IPv6 profile, with optional numeric port. Only SP/HTAB are trimmed around field values.
Duplicate Host/Content-Length, invalid header names/control bytes, and ambiguous framing
return 400. Unsupported transfer encoding returns 501; Expect returns 417. HEAD sends
no body but retains the selected representation's length. No keep-alive or pipelining:
trailing bytes are discarded at close. Parser errors remain plain text; application errors
use the JSON helper below. These are bounded experimental protocol rules, not a claim
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
| read_timeout_ms | 5000 | 1..86400000, total read phase |
| write_timeout_ms | 5000 | 1..86400000, total write phase |
| poll_timeout_ms | 10 | 1..1000, capped by nearest active deadline |
| shutdown_grace_ms | 5000 | 0..86400000 |
| max_requests | 0 | nonnegative; 0 unlimited |
| handle_signals | false | opt-in process-wide SIGINT/SIGTERM ownership |

`validate_server_config(config)` rejects invalid combinations before opening a socket.
`serve_config(config, control, handler, tick, lifecycle)` returns false on invalid
configuration, bind/signal setup failure, or fatal poll failure. Handler receives
request/response, tick receives no arguments, and lifecycle receives stage/stats.
All callbacks are synchronous. Tick can capture `control` and call `request_shutdown(control)`.

Lifecycle stages are `SERVER_STARTED`, `SERVER_STOPPING`, and `SERVER_STOPPED`.
Shutdown closes the listener and drains already accepted clients until the grace
period expires. `max_requests` triggers this drain; accepted work may take completed
responses past the threshold. `shutdown_requested` remains latched: clear it, or use
a fresh control, before restarting. Stats reset on a successful new run.

`control.stats` reports accepted (including capacity rejections), active, completed
(fully transmitted responses, including HTTP errors), rejected (capacity), timeouts,
forced_closes (grace/fatal cleanup), bytes_read, and bytes_written. Protocol errors
are not capacity rejections. Idle timeout closes the socket without a response.

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
