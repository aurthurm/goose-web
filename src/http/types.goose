import std;
import src.constants.limits;
namespace web;

// peer is the client's numeric address, set by the runtime after parsing; "" when unknown.
struct Request {
    method: const u8[:], target: const u8[:], body: const u8[:], raw_headers: const u8[:],
    peer: const u8[:] = ""
}
struct Header { name: u8[..MAX_HEADER_NAME_BYTES], value: u8[..MAX_HEADER_VALUE_BYTES] }
// The body is body[body_start..]. Writes only append (see response.goose), so the buffer
// grows with what a request writes and is cleared by the runtime after serialization.
// sse: the handler called c.sse(sse_channel); the runtime upgrades the connection to a stream.
// set_cookie_line holds one long Set-Cookie line (see MAX_COOKIE_LINE_BYTES); empty when unused.
// body is the resizable tail: it must stay the last field.
struct Response {
    status: i32, content_type: u8[..MAX_CONTENT_TYPE_BYTES], headers: Header[..MAX_RESPONSE_HEADERS],
    set_cookie_line: u8[..MAX_COOKIE_LINE_BYTES],
    body_start: i64, max_body: i64, sse: bool, sse_channel: i32, body: u8[>..]
}
