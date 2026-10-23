import src.constants.http;
import src.constants.limits;
import .types;
import .headers;
import std;
namespace web;

fn response() -> Response {
    return Response { status: HTTP_OK, content_type: CONTENT_TYPE_TEXT, body: [], headers: [] };
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

// close: send Connection: close. keep_alive: send Connection: keep-alive, which only
// HTTP/1.0 clients need. Neither set means HTTP/1.1 persistence without a field.
fn serialize_response(out: u8[>..]&, r: Response&, head: bool = false, close: bool = true, keep_alive: bool = false) {
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
        r.body = "Invalid response\n";
        r.headers.clear();
    }
    let no_body = r.status == HTTP_NO_CONTENT || r.status == HTTP_NOT_MODIFIED;
    format(out, HTTP_VERSION, " ", r.status, " ", reason(r.status), "\r\n");
    if close { format(out, HEADER_CONNECTION, ": ", CONNECTION_CLOSE, "\r\n"); }
    else if keep_alive { format(out, HEADER_CONNECTION, ": ", CONNECTION_KEEP_ALIVE, "\r\n"); }
    if !no_body { format(out, HEADER_CONTENT_LENGTH, ": ", r.body.len, "\r\n"); }
    format(out, HEADER_CONTENT_TYPE, ": ", r.content_type, "\r\n");
    for h in r.headers { format(out, h.name, ": ", h.value, "\r\n"); }
    out.append("\r\n");
    if !head && !no_body { out.append(r.body); }
}
