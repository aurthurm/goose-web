import .types;
import .headers;
import std;
namespace web;

// HTTP optional whitespace is SP / HTAB, not general Unicode/text whitespace.
fn request_ows(value: const u8[:]) -> const u8[:] {
    var first: i64 = 0;
    var last = value.len;
    while first < last && (value[first] == 32 || value[first] == 9) { first += 1; }
    while last > first && (value[last - 1] == 32 || value[last - 1] == 9) { last -= 1; }
    return value[first..last];
}

fn request_hex(c: u8) -> bool {
    return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
}
fn request_uri_char(c: u8) -> bool {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
           (c >= '0' && c <= '9') || find("-._~!$&'()*+,;=", [c]) >= 0;
}
// RFC 3986 pchar plus path/query delimiters; preserve escaped octets as-is.
fn request_target_valid(target: const u8[:]) -> bool {
    if target.len == 0 || target[0] != '/' { return false; }
    var pos: i64 = 0;
    while pos < target.len {
        let c = target[pos];
        if c == '%' {
            if target.len - pos < 3 || !request_hex(target[pos + 1]) || !request_hex(target[pos + 2]) { return false; }
            pos += 3;
        } else {
            if !request_uri_char(c) && c != ':' && c != '@' && c != '/' && c != '?' { return false; }
            pos += 1;
        }
    }
    return true;
}

fn request_ipv4(value: const u8[:]) -> bool {
    var pos: i64 = 0;
    for part in 4 {
        let start = pos;
        var number: i64 = 0;
        while pos < value.len && value[pos] >= '0' && value[pos] <= '9' {
            number = number * 10 + (value[pos] - '0');
            pos += 1;
            if pos - start > 3 || number > 255 { return false; }
        }
        if pos == start || (pos - start > 1 && value[start] == '0') { return false; }
        if part < 3 {
            if pos == value.len || value[pos] != '.' { return false; }
            pos += 1;
        }
    }
    return pos == value.len;
}

// Count groups in one side of ::. An IPv4 tail occupies two groups and may
// occur only at the very end of the whole address.
fn request_ipv6_groups(value: const u8[:], allow_ipv4: bool) -> i64 {
    if value.len == 0 { return 0; }
    var pos: i64 = 0;
    var groups: i64 = 0;
    loop {
        let offset = find(value[pos..], ":");
        let end = if offset < 0 { value.len } else { pos + offset };
        let part = value[pos..end];
        if find(part, ".") >= 0 {
            if end != value.len || !allow_ipv4 || !request_ipv4(part) { return -1; }
            groups += 2;
        } else {
            if part.len == 0 || part.len > 4 { return -1; }
            for c in part { if !request_hex(c) { return -1; } }
            groups += 1;
        }
        if groups > 8 { return -1; }
        if end == value.len { return groups; }
        pos = end + 1;
    }
}
fn request_ipv6(value: const u8[:]) -> bool {
    let compressed = find(value, "::");
    if compressed < 0 { return request_ipv6_groups(value, true) == 8; }
    let left = request_ipv6_groups(value[..compressed], false);
    let right = request_ipv6_groups(value[compressed + 2..], true);
    return left >= 0 && right >= 0 && left + right < 8;
}

// A nonempty RFC 3986 reg-name or bracketed IPv6, optionally followed by a
// numeric TCP port. IPvFuture, scoped IPv6, empty ports and >65535 are outside
// this server's deliberately restricted Host profile.
fn request_host_valid(value: const u8[:]) -> bool {
    if value.len == 0 { return false; }
    var port: i64 = -1;
    if value[0] == '[' {
        let end = find(value, "]");
        if end < 0 || !request_ipv6(value[1..end]) { return false; }
        if end + 1 < value.len {
            if value[end + 1] != ':' { return false; }
            port = end + 2;
        }
    } else {
        let colon = find(value, ":");
        let end = if colon < 0 { value.len } else { colon };
        if end == 0 { return false; }
        var pos: i64 = 0;
        while pos < end {
            if value[pos] == '%' {
                if end - pos < 3 || !request_hex(value[pos + 1]) || !request_hex(value[pos + 2]) { return false; }
                pos += 3;
            } else {
                if !request_uri_char(value[pos]) { return false; }
                pos += 1;
            }
        }
        if colon >= 0 { port = colon + 1; }
    }
    if port >= 0 {
        if port == value.len { return false; }
        var number: i64 = 0;
        for c in value[port..] {
            if c < '0' || c > '9' { return false; }
            number = number * 10 + (c - '0');
            if number > 65535 { return false; }
        }
    }
    return true;
}

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
        if equal_header(line[..colon], name) { return request_ows(line[colon + 1..]); }
        pos += end + 2;
    }
    return "";
}

// Result 0 = incomplete, 200 = complete, otherwise an HTTP error status.
// Views borrow raw: handlers finish before the connection slot is reused.
fn parse_request(raw: const u8[:]) -> Request, i32 {
    let empty = Request { method: raw[..0], target: raw[..0], body: raw[..0], raw_headers: raw[..0] };
    let end = find(raw, "\r\n\r\n");
    // Scan only the header region. A final CR can still become CRLF in the
    // next network read; body bytes are never inspected as header syntax.
    let header_limit = if end < 0 { raw.len } else { end + 4 };
    for i in header_limit {
        if raw[i] == 10 && (i == 0 || raw[i - 1] != 13) { return empty, 400; }
        if raw[i] == 13 && i + 1 < header_limit && raw[i + 1] != 10 { return empty, 400; }
    }
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
    if !request_target_valid(target) { return empty, 400; }
    let version = rest[second + 1..];
    if version.len != 8 || version[..5] != "HTTP/" || version[6] != '.' ||
       version[5] < '0' || version[5] > '9' || version[7] < '0' || version[7] > '9' { return empty, 400; }
    if version != "HTTP/1.1" { return empty, 505; }
    var length: i64 = 0;
    var length_large = false;
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
        let value = request_ows(header[colon + 1..]);
        for c in header[colon + 1..] {
            if (c < 32 && c != 9) || c == 127 { return empty, 400; }
        }
        if equal_header(name, "host") {
            if have_host || !request_host_valid(value) { return empty, 400; }
            have_host = true;
        }
        if equal_header(name, "content-length") {
            if have_length || value.len == 0 { return empty, 400; }
            have_length = true;
            for c in value {
                if c < '0' || c > '9' { return empty, 400; }
                // Saturate at the request limit, validating remaining digits.
                // Arbitrarily many leading zeroes are safe and stay valid.
                if !length_large {
                    length = length * 10 + (c - '0');
                    if length > MAX_REQUEST { length_large = true; }
                }
            }
        }
        if equal_header(name, "transfer-encoding") { transfer = true; }
        if equal_header(name, "expect") { expect = true; }
        pos += n + 2;
    }
    if !have_host { return empty, 400; }
    if transfer && have_length { return empty, 400; }
    if length_large { return empty, 413; }
    if transfer { return empty, 501; }
    if expect { return empty, 417; }
    let body_start = end + 4;
    if length > MAX_REQUEST - body_start { return empty, 413; }
    if raw.len < body_start + length { return empty, 0; }
    return Request { method: line[..first], target: target,
                     body: raw[body_start..body_start + length], raw_headers: raw[line_end + 2..end + 2] }, 200;
}
