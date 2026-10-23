import src.constants.http;
import src.constants.limits;
import src.http.types;
import src.http.request;
import src.http.response;
import src.http.headers;
import src.http.errors;
import src.routing.router;
import src.app.openapi_state;
import std;
namespace web;

// Group prefixes nest this deep. Fixed so a Ctx stays a plain value on the stack.
const MAX_GROUP_DEPTH = 8;
const MAX_I64_VALUE = 9223372036854775807;
// Route pass state. Idle means no c.routes() block is active. Describe runs the block
// only to collect OpenAPI operations; no route body runs in it.
const PASS_IDLE = 0;
const PASS_MATCH = 1;
const PASS_DISPATCH = 2;
const PASS_DESCRIBE = 3;

// One value per request, owned by the server loop for the duration of the handler.
// The response is borrowed: the runtime owns one reused Response (see run.goose), so a
// Ctx stays a fixed-size value. Routing fields are scratch for c.routes(); c.routes()
// resets them on every entry.
struct Ctx {
    request: Request,
    response: Response&,
    request_id: i64,
    written: bool,
    pass: i32,
    route_index: i64,
    table: Router,
    matched: RouteMatch,
    prefixes: const u8[:][MAX_GROUP_DEPTH],
    prefix_count: i64,
    oas: OpenApiState,
}

// Routing state zeroed; the response is the caller's (tests and the runtime create it with response()).
fn new_ctx(request: Request, response: Response&) -> Ctx {
    return Ctx { request: request, response: response, .. };
}

fn method(c: Ctx&) -> const u8[:] { return c.request.method; }
fn target(c: Ctx&) -> const u8[:] { return c.request.target; }
fn path(c: Ctx&) -> const u8[:] { return target_path(c.request.target); }
fn header(c: Ctx&, name: const u8[:]) -> const u8[:] { return request_header(c.request, name); }

// Path parameters of the selected route. Empty when absent or before dispatch.
fn param(c: Ctx&, name: const u8[:]) -> const u8[:] { return path_param(c.matched, name); }

// Canonical non-negative decimal: no sign, no leading zeros, and no i64 overflow.
// Returns 0 with false on any violation.
fn parse_canonical(text: const u8[:]) -> i64, bool {
    if text.len == 0 || (text[0] == '0' && text.len > 1) { return 0, false; }
    var value: i64 = 0;
    for ch in text {
        if ch < '0' || ch > '9' { return 0, false; }
        let digit = (ch - '0') as i64;
        if value > (MAX_I64_VALUE - digit) / 10 { return 0, false; }
        value = value * 10 + digit;
    }
    return value, true;
}

fn status(c: Ctx&, code: i32) -> Ctx& {
    assert(code >= HTTP_MIN_RESPONSE_STATUS && code <= HTTP_MAX_STATUS);
    c.response.status = code;
    c.written = true;
    return c;
}

// Response header setter. Invalid names or values are programmer errors here.
fn set(c: Ctx&, name: const u8[:], value: const u8[:]) -> Ctx& {
    assert(set_header(c.response, name, value));
    return c;
}

// Writes an error envelope and marks the response as written.
fn fail(c: Ctx&, code: i32, error_code: const u8[:], message: const u8[:]) {
    c.written = true;
    application_error(c.response, code, error_code, message);
}

// Bodies over the response's max_body become a complete 500 instead of a truncated reply.
fn write_body(c: Ctx&, content_type: const u8[:], body: const u8[:]) {
    c.written = true;
    if !set_body(c.response, body) {
        application_error(c.response, HTTP_INTERNAL_SERVER_ERROR, "response_too_large", "Response body exceeds capacity");
        return;
    }
    c.response.content_type = content_type;
}

fn text(c: Ctx&, body: const u8[:]) { write_body(c, CONTENT_TYPE_TEXT, body); }
fn html(c: Ctx&, body: const u8[:]) { write_body(c, CONTENT_TYPE_HTML, body); }
fn json_raw(c: Ctx&, body: const u8[:]) { write_body(c, CONTENT_TYPE_JSON, body); }

fn no_content(c: Ctx&) {
    c.written = true;
    c.response.status = HTTP_NO_CONTENT;
    drop_body(c.response);
}

// Location must be a valid header value; a bad target is reported as a 500 envelope
// rather than a silent redirect to nowhere. The status must be a 3xx code.
fn redirect(c: Ctx&, location: const u8[:], code: i32 = HTTP_FOUND) {
    assert(code >= HTTP_MOVED_PERMANENTLY && code < HTTP_NOT_FOUND);
    c.written = true;
    if !set_header(c.response, HEADER_LOCATION, location) {
        application_error(c.response, HTTP_INTERNAL_SERVER_ERROR, "invalid_redirect", "Redirect location is invalid");
        return;
    }
    c.response.status = code;
    drop_body(c.response);
}

fn done(c: Ctx&) -> bool { return c.written; }

// Path parameter as a canonical integer. On failure writes 422 invalid_param.
fn param_int(c: Ctx&, name: const u8[:]) -> i64, bool {
    let value, ok = parse_canonical(path_param(c.matched, name));
    if !ok {
        fail(c, HTTP_UNPROCESSABLE_CONTENT, "invalid_param", "Path parameter must be a canonical non-negative integer");
        return 0, false;
    }
    return value, true;
}

fn query(c: Ctx&, key: const u8[:]) -> QueryValue { return query_value(c.request.target, key); }

// Missing keys yield fallback with true. Bad escapes, overflow, and non-canonical
// integers write 400 invalid_query and return false.
fn query_int(c: Ctx&, key: const u8[:], fallback: i64) -> i64, bool {
    let raw = query_value(c.request.target, key);
    if raw.status == QUERY_MISSING { return fallback, true; }
    if raw.status != HTTP_OK {
        fail(c, HTTP_BAD_REQUEST, "invalid_query", "Query value could not be decoded");
        return 0, false;
    }
    let value, ok = parse_canonical(raw.value[..]);
    if !ok {
        fail(c, HTTP_BAD_REQUEST, "invalid_query", "Query value must be a canonical non-negative integer");
        return 0, false;
    }
    return value, true;
}
