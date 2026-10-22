import .types;
import std;
namespace web;

fn token(s: u8[:]) -> bool {
    if s.len == 0 { return false; }
    for c in s {
        if !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
             (c >= '0' && c <= '9') || find("!#$%&'*+-.^_`|~", [c]) >= 0) {
            return false;
        }
    }
    return true;
}

fn equal_header(a: u8[:], b: u8[:]) -> bool {
    if a.len != b.len { return false; }
    for i in a.len {
        var c = a[i];
        var d = b[i];
        if c >= 'A' && c <= 'Z' { c += 32; }
        if d >= 'A' && d <= 'Z' { d += 32; }
        if c != d { return false; }
    }
    return true;
}

fn valid_response_header(name: const u8[:], value: const u8[:]) -> bool {
    if name.len > 64 || value.len > 256 || !token(name) { return false; }
    if equal_header(name, "content-length") || equal_header(name, "transfer-encoding") ||
       equal_header(name, "connection") || equal_header(name, "content-type") ||
       equal_header(name, "trailer") || equal_header(name, "upgrade") { return false; }
    for c in value { if c < 32 || c == 127 { return false; } }
    return true;
}

// Replace case-insensitively; failure leaves the response unchanged.
fn set_header(r: Response&, name: const u8[:], value: const u8[:]) -> bool {
    if !valid_response_header(name, value) { return false; }
    for i in r.headers.len {
        if equal_header(r.headers[i].name, name) {
            r.headers[i].value = value;
            return true;
        }
    }
    if r.headers.len == 16 { return false; }
    r.headers.push(Header { name: name, value: value });
    return true;
}
