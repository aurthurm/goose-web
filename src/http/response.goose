import src.constants.http;
import src.constants.limits;
import src.constants.runtime;
import .types;
import .headers;
import std;
namespace web;

// A fresh response: 200, text/plain, no headers, empty body. max_body is the runtime's cap.
fn response() -> Response {
    return Response { status: HTTP_OK, content_type: CONTENT_TYPE_TEXT, headers: [], body_start: 0,
        max_body: DEFAULT_MAX_RESPONSE_BYTES, body: [] };
}

// The current body. The view is valid until the next write or runtime reset.
fn body_of(r: Response&) -> const u8[:] { return r.body[r.body_start..]; }
fn body_len(r: Response&) -> i64 { return r.body.len - r.body_start; }

// Writes append to the buffer and make the new bytes the body. The buffer never shrinks
// while a handler runs, so views taken earlier stay valid, and set_body(r, body_of(r)) is
// safe. The cap counts every byte the buffer holds, so memory stays bounded by max_body.
// On false the response is unchanged.
fn append_body(r: Response&, s: const u8[:]) -> bool {
    if s.len > r.max_body - r.body.len { return false; }
    r.body.append(s);
    return true;
}
fn set_body(r: Response&, s: const u8[:]) -> bool {
    let at = r.body.len;
    if !append_body(r, s) { return false; }
    r.body_start = at;
    return true;
}
// Error envelopes may use MAX_ERROR_BODY_BYTES beyond max_body, so a refused write can
// still be replaced by its 500. Only errors use this room.
fn error_set_body(r: Response&, s: const u8[:]) -> bool {
    if s.len > r.max_body + MAX_ERROR_BODY_BYTES - r.body.len { return false; }
    let at = r.body.len;
    r.body.append(s);
    r.body_start = at;
    return true;
}
// Drops the current body from the response. The buffer keeps its bytes until the runtime clears it.
fn drop_body(r: Response&) { r.body_start = r.body.len; }

// Runtime use: after a response is serialized no views are live, so the buffer can be cleared
// and reused for the next request. Keeps the capacity.
fn reset_response(r: Response&) {
    r.status = HTTP_OK;
    r.content_type = CONTENT_TYPE_TEXT;
    r.headers.clear();
    r.body.clear();
    r.body_start = 0;
}

fn reason(status: i32) -> const u8[:] {
    match status {
        HTTP_OK => { return "OK"; },
        HTTP_CREATED => { return "Created"; },
        HTTP_ACCEPTED => { return "Accepted"; },
        HTTP_NO_CONTENT => { return "No Content"; },
        HTTP_PARTIAL_CONTENT => { return "Partial Content"; },
        HTTP_MOVED_PERMANENTLY => { return "Moved Permanently"; },
        HTTP_FOUND => { return "Found"; },
        HTTP_SEE_OTHER => { return "See Other"; },
        HTTP_NOT_MODIFIED => { return "Not Modified"; },
        HTTP_TEMPORARY_REDIRECT => { return "Temporary Redirect"; },
        HTTP_PERMANENT_REDIRECT => { return "Permanent Redirect"; },
        HTTP_BAD_REQUEST => { return "Bad Request"; },
        HTTP_UNAUTHORIZED => { return "Unauthorized"; },
        HTTP_FORBIDDEN => { return "Forbidden"; },
        HTTP_NOT_FOUND => { return "Not Found"; },
        HTTP_METHOD_NOT_ALLOWED => { return "Method Not Allowed"; },
        HTTP_REQUEST_TIMEOUT => { return "Request Timeout"; },
        HTTP_CONFLICT => { return "Conflict"; },
        HTTP_GONE => { return "Gone"; },
        HTTP_CONTENT_TOO_LARGE => { return "Content Too Large"; },
        HTTP_UNSUPPORTED_MEDIA_TYPE => { return "Unsupported Media Type"; },
        HTTP_EXPECTATION_FAILED => { return "Expectation Failed"; },
        HTTP_UNPROCESSABLE_CONTENT => { return "Unprocessable Content"; },
        HTTP_TOO_MANY_REQUESTS => { return "Too Many Requests"; },
        HTTP_REQUEST_HEADER_FIELDS_TOO_LARGE => { return "Request Header Fields Too Large"; },
        HTTP_INTERNAL_SERVER_ERROR => { return "Internal Server Error"; },
        HTTP_NOT_IMPLEMENTED => { return "Not Implemented"; },
        HTTP_BAD_GATEWAY => { return "Bad Gateway"; },
        HTTP_SERVICE_UNAVAILABLE => { return "Service Unavailable"; },
        HTTP_GATEWAY_TIMEOUT => { return "Gateway Timeout"; },
        HTTP_VERSION_NOT_SUPPORTED => { return "HTTP Version Not Supported"; },
        _ => { return "Response"; }
    }
}

// Invalid status, content type or headers become a 500 with a fixed body.
fn prepare_response(r: Response&) {
    var valid = r.status >= HTTP_MIN_RESPONSE_STATUS && r.status <= HTTP_MAX_STATUS && r.content_type.len > 0;
    for c in r.content_type { if c < 32 || c == 127 { valid = false; } }
    for h in r.headers {
        if !valid_response_header(h.name, h.value) { valid = false; }
    }
    for i in r.headers.len {
        for j in i + 1..r.headers.len {
            // Set-Cookie may repeat; any other duplicate name is invalid.
            if equal_header(r.headers[i].name, r.headers[j].name) && !equal_header(r.headers[i].name, HEADER_SET_COOKIE) { valid = false; }
        }
    }
    if !valid {
        r.status = HTTP_INTERNAL_SERVER_ERROR;
        r.content_type = CONTENT_TYPE_TEXT;
        r.headers.clear();
        drop_body(r);
        error_set_body(r, "Invalid response\n");
    }
}

// Status line and headers, ending with the blank line. Content-Length is the body length.
// close: send Connection: close. keep_alive: send Connection: keep-alive, which only
// HTTP/1.0 clients need. Neither set means HTTP/1.1 persistence without a field.
fn serialize_head(out: u8[>..]&, r: Response&, close: bool, keep_alive: bool) {
    let no_body = r.status == HTTP_NO_CONTENT || r.status == HTTP_NOT_MODIFIED;
    format(out, HTTP_VERSION, " ", r.status, " ", reason(r.status), "\r\n");
    if close { format(out, HEADER_CONNECTION, ": ", CONNECTION_CLOSE, "\r\n"); }
    else if keep_alive { format(out, HEADER_CONNECTION, ": ", CONNECTION_KEEP_ALIVE, "\r\n"); }
    if !no_body { format(out, HEADER_CONTENT_LENGTH, ": ", body_len(r), "\r\n"); }
    format(out, HEADER_CONTENT_TYPE, ": ", r.content_type, "\r\n");
    for h in r.headers { format(out, h.name, ": ", h.value, "\r\n"); }
    out.append("\r\n");
}

// Whether the body follows the head: HEAD requests and 204/304 responses carry none.
fn sends_body(r: Response&, head: bool) -> bool {
    return !head && r.status != HTTP_NO_CONTENT && r.status != HTTP_NOT_MODIFIED;
}

fn serialize_response(out: u8[>..]&, r: Response&, head: bool = false, close: bool = true, keep_alive: bool = false) {
    prepare_response(r);
    serialize_head(out, r, close, keep_alive);
    if sends_body(r, head) { out.append(body_of(r)); }
}
