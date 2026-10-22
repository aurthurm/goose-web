import .types;
import .headers;
import std;
namespace web;

// Lookup parsed headers without copying; names are case-insensitive. The first
// value is returned, empty for missing. Call only with a parsed Request.
fn request_header(request: Request, name: const u8[:]) -> const u8[:] {
    var pos: i64 = 0;
    while pos < request.raw_headers.len {
        let rest = request.raw_headers[pos..];
        let end = find(rest, "\r\n");
        if end < 0 { return ""; }
        let line = rest[..end];
        let colon = find(line, ":");
        if colon <= 0 { return ""; }
        if equal_header(line[..colon], name) { return trim(line[colon + 1..]); }
        pos += end + 2;
    }
    return "";
}

// Result 0 = incomplete, 200 = complete, otherwise an HTTP error status.
// Views borrow raw: handlers finish before the connection slot is reused.
fn parse_request(raw: const u8[:]) -> Request, i32 {
    let empty = Request { method: raw[..0], target: raw[..0], body: raw[..0], raw_headers: raw[..0] };
    let end = find(raw, "\r\n\r\n");
    if end < 0 {
        return empty, if raw.len >= MAX_REQUEST { 431 } else { 0 };
    }
    if raw.len > MAX_REQUEST { return empty, 413; }
    let line_end = find(raw, "\r\n");
    let line = raw[..line_end];
    let first = find(line, " ");
    if first <= 0 { return empty, 400; }
    let rest = line[first + 1..];
    let second = find(rest, " ");
    if second <= 0 || !token(line[..first]) { return empty, 400; }
    let target = rest[..second];
    if target[0] != '/' { return empty, 400; }
    for c in target { if c <= 32 || c == 127 { return empty, 400; } }
    if rest[second + 1..] != "HTTP/1.1" { return empty, 505; }
    var length: i64 = 0;
    var have_length = false;
    var have_host = false;
    var transfer = false;
    var expect = false;
    var pos = line_end + 2;
    while pos < end {
        let n = find(raw[pos..], "\r\n");
        let header = raw[pos..pos + n];
        let colon = find(header, ":");
        if colon <= 0 || !token(header[..colon]) { return empty, 400; }
        let name = header[..colon];
        let value = trim(header[colon + 1..]);
        for c in header[colon + 1..] {
            if (c < 32 && c != 9) || c == 127 { return empty, 400; }
        }
        if equal_header(name, "host") {
            if have_host || value.len == 0 { return empty, 400; }
            have_host = true;
        }
        if equal_header(name, "content-length") {
            if have_length || value.len == 0 { return empty, 400; }
            have_length = true;
            for c in value {
                if c < '0' || c > '9' { return empty, 400; }
                // Bound before multiplication, so hostile numbers cannot overflow.
                if length > MAX_REQUEST { return empty, 413; }
                length = length * 10 + (c - '0');
            }
        }
        if equal_header(name, "transfer-encoding") { transfer = true; }
        if equal_header(name, "expect") { expect = true; }
        pos += n + 2;
    }
    if !have_host { return empty, 400; }
    if transfer && have_length { return empty, 400; }
    if transfer { return empty, 501; }
    if expect { return empty, 417; }
    let body_start = end + 4;
    if length > MAX_REQUEST - body_start { return empty, 413; }
    if raw.len < body_start + length { return empty, 0; }
    return Request { method: line[..first], target: target,
                     body: raw[body_start..body_start + length], raw_headers: raw[line_end + 2..end + 2] }, 200;
}
