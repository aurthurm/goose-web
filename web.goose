// Goose Web routing primitives. The native transport experiment lives separately.
// Early API: implementation subject to change.
import std;

// Match a literal segment or a named parameter (":id").
// Only complete path segments match; empty names are rejected.
// This matcher does not normalize or percent-decode URLs.
fn route_matches(pattern: u8[:], path: u8[:]) -> bool {
    var pi: i64 = 0;
    var si: i64 = 0;
    loop {
        if pi == pattern.len || si == path.len {
            return pi == pattern.len && si == path.len;
        }
        let pstart = pi;
        let sstart = si;
        while pi < pattern.len && pattern[pi] != '/' { pi++; }
        while si < path.len && path[si] != '/' { si++; }
        let ps = pattern[pstart..pi];
        let ss = path[sstart..si];
        if ps.len > 0 && ps[0] == ':' {
            if ps.len == 1 || ss.len == 0 { return false; }
        } else if ps != ss { return false; }
        if pi == pattern.len || si == path.len {
            return pi == pattern.len && si == path.len;
        }
        pi++;
        si++;
    }
}

fn status_reason(status: i32) -> u8[:] {
    if status == 200 { return "OK"; }
    if status == 201 { return "Created"; }
    if status == 204 { return "No Content"; }
    if status == 400 { return "Bad Request"; }
    if status == 404 { return "Not Found"; }
    if status == 405 { return "Method Not Allowed"; }
    if status == 413 { return "Content Too Large"; }
    if status == 500 { return "Internal Server Error"; }
    if status == 503 { return "Service Unavailable"; }
    return "Unknown";
}
