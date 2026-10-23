import src.constants.http;
import src.constants.limits;
import src.http.headers;
import src.http.errors;
import src.http.request;
import src.app.context;
import src.app.respond;
import std;
namespace web;

// Middleware is `fn name<Next>(c: Ctx&, ...) { before; Next(); after; }`: the block
// after the call is Next, and not calling it short-circuits the request.

const HEADER_ACCESS_CONTROL_ALLOW_ORIGIN = "Access-Control-Allow-Origin";
const HEADER_ACCESS_CONTROL_ALLOW_METHODS = "Access-Control-Allow-Methods";
const HEADER_ACCESS_CONTROL_ALLOW_HEADERS = "Access-Control-Allow-Headers";
const HEADER_ACCESS_CONTROL_MAX_AGE = "Access-Control-Max-Age";
const HEADER_ACCESS_CONTROL_REQUEST_METHOD = "Access-Control-Request-Method";
const HEADER_ACCESS_CONTROL_REQUEST_HEADERS = "Access-Control-Request-Headers";
const HEADER_VARY = "Vary";
const CORS_ALLOW_METHODS = "GET, POST, PUT, PATCH, DELETE, OPTIONS";
const CORS_DEFAULT_ALLOW_HEADERS = "Content-Type";
const CORS_MAX_AGE_SECONDS = "600";

// Process-global, so ids stay unique across all connections on this reactor thread.
var request_counter: i64 = 0;

// Assigns the next id, stores it in c.request_id, and sets X-Request-ID before Next.
fn request_id<Next>(c: Ctx&) {
    request_counter += 1;
    c.request_id = request_counter;
    var text: u8[>..] = [];
    format(text, request_counter);
    c.set(HEADER_REQUEST_ID, text[..]);
    Next();
}

// Replaces control bytes so a crafted target cannot split the log line.
fn log_text(out: u8[>..]&, text: const u8[:]) {
    for ch in text {
        if ch < 32 || ch == 127 { out.push('?'); } else { out.push(ch); }
    }
}

// Prints one line after Next: METHOD path status bytes. Runs after the inner chain,
// including after a cors preflight short-circuit. Control bytes are masked, never fatal.
fn logger<Next>(c: Ctx&) {
    Next();
    var line: u8[>..] = [];
    log_text(line, c.method());
    line.push(' ');
    log_text(line, c.path());
    format(line, " ", c.response.status, " ", body_len(c.response));
    print(line);
}

// Adds Vary: Origin whenever the allowed origin is not the wildcard, so caches keyed on
// the request origin do not serve one origin's answer to another.
fn cors_origin_headers(c: Ctx&, origin: const u8[:]) {
    c.set(HEADER_ACCESS_CONTROL_ALLOW_ORIGIN, origin);
    if origin != "*" { c.set(HEADER_VARY, "Origin"); }
}

// Preflight: OPTIONS carrying Access-Control-Request-Method is answered here with 204
// and Next is not called, so routes and handlers never see preflight traffic.
fn cors<Next>(c: Ctx&, origin: const u8[:] = "*") {
    if c.method() == METHOD_OPTIONS && c.header(HEADER_ACCESS_CONTROL_REQUEST_METHOD).len > 0 {
        cors_origin_headers(c, origin);
        c.set(HEADER_ACCESS_CONTROL_ALLOW_METHODS, CORS_ALLOW_METHODS);
        // Echo the requested headers only when they are a valid header value.
        let requested = c.header(HEADER_ACCESS_CONTROL_REQUEST_HEADERS);
        let allow = if requested.len > 0 && valid_response_header(HEADER_ACCESS_CONTROL_ALLOW_HEADERS, requested) {
            requested
        } else {
            CORS_DEFAULT_ALLOW_HEADERS
        };
        c.set(HEADER_ACCESS_CONTROL_ALLOW_HEADERS, allow);
        c.set(HEADER_ACCESS_CONTROL_MAX_AGE, CORS_MAX_AGE_SECONDS);
        c.no_content();
        return;
    }
    cors_origin_headers(c, origin);
    Next();
}

// Rejects any request whose Content-Type media type is not application/json. The
// check applies to every request inside the block, so wrap body-carrying routes.
fn require_json<Next>(c: Ctx&) {
    if !is_json_media_type(c.header(HEADER_CONTENT_TYPE)) {
        c.fail(HTTP_UNSUPPORTED_MEDIA_TYPE, "unsupported_media_type", "Content-Type must be application/json");
        return;
    }
    Next();
}
