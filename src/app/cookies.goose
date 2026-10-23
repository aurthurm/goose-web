import src.constants.http;
import src.constants.limits;
import src.http.headers;
import src.http.request;
import src.app.context;
import std;
namespace web;

// Cookies (RFC 6265). c.cookie reads the request's Cookie header; c.set_cookie appends one
// Set-Cookie line per call. Both are plain string work on the bounded header storage.

struct CookieOptions {
    path: u8[..64] = "/",
    max_age: i64 = -1,
    http_only: bool = true,
    secure: bool = false,
    same_site: u8[..8] = "Lax",
}

// Removes one pair of DQUOTEs around a cookie value (cookie-value = DQUOTE *cookie-octet DQUOTE).
fn cookie_unquote(value: const u8[:]) -> const u8[:] {
    if value.len >= 2 && value[0] == '"' && value[value.len - 1] == '"' { return value[1..value.len - 1]; }
    return value;
}

// First pair named `name` in one cookie-string. Pairs are split on ';' and trimmed of SP/HTAB;
// names match exactly. A pair without '=' or with an empty name is ignored.
fn cookie_lookup(raw: const u8[:], name: const u8[:]) -> const u8[:] {
    if name.len == 0 { return ""; }
    var pos: i64 = 0;
    loop {
        let semi = find(raw[pos..], ";");
        let end = if semi < 0 { raw.len } else { pos + semi };
        let pair = request_ows(raw[pos..end]);
        let equals = find(pair, "=");
        if equals > 0 && request_ows(pair[..equals]) == name {
            return cookie_unquote(request_ows(pair[equals + 1..]));
        }
        if semi < 0 { return ""; }
        pos = end + 1;
    }
}

// Value of the first cookie named `name` in the request's first Cookie header, or "" when
// absent. Only the first Cookie header is read (HTTP/1.1 clients send one). Values are
// returned as sent, so a malformed value is visible to the caller, which must validate it.
fn cookie(c: Ctx&, name: const u8[:]) -> const u8[:] {
    return cookie_lookup(request_header(c.request, HEADER_COOKIE), name);
}

// Cookie-octet from RFC 6265: %x21 / %x23-2B / %x2D-3A / %x3C-5B / %x5D-7E.
fn cookie_octet(ch: u8) -> bool {
    return ch == '!' || (ch >= '#' && ch <= '+') || (ch >= '-' && ch <= ':') ||
           (ch >= '<' && ch <= '[') || (ch >= ']' && ch <= '~');
}

fn cookie_value_valid(value: const u8[:]) -> bool {
    for ch in value {
        if !cookie_octet(ch) { return false; }
    }
    return true;
}

// Empty means the Path attribute is omitted. Otherwise it must be absolute and free of
// controls and ';', which would end the attribute.
fn cookie_path_valid(path: const u8[:]) -> bool {
    if path.len == 0 { return true; }
    if path[0] != '/' { return false; }
    for ch in path {
        if ch < 32 || ch == 127 || ch == ';' { return false; }
    }
    return true;
}

// Canonical SameSite spelling. Empty omits the attribute; any other unknown value is invalid.
fn cookie_same_site(value: const u8[:]) -> const u8[:], bool {
    if value.len == 0 { return "", true; }
    if equal_header(value, "Strict") { return "Strict", true; }
    if equal_header(value, "Lax") { return "Lax", true; }
    if equal_header(value, "None") { return "None", true; }
    return "", false;
}

// Appends `Set-Cookie: name=value; ...` to the response. Returns false, and changes nothing,
// when the name is not a token, the value has characters outside cookie-octet, an option is
// invalid, SameSite=None is used without Secure, or the line exceeds the header capacity.
// A negative max_age omits Max-Age; zero asks the client to delete the cookie at once.
fn set_cookie(c: Ctx&, name: const u8[:], value: const u8[:], opts: CookieOptions = CookieOptions { .. }) -> bool {
    if !token(name) || !cookie_value_valid(value) || !cookie_path_valid(opts.path[..]) { return false; }
    let same_site, same_site_ok = cookie_same_site(opts.same_site[..]);
    if !same_site_ok { return false; }
    if equal_header(same_site, "None") && !opts.secure { return false; }
    var line: u8[>..] = [];
    format(line, name, "=", value);
    if opts.path.len > 0 { format(line, "; Path=", opts.path[..]); }
    if opts.max_age >= 0 { format(line, "; Max-Age=", opts.max_age); }
    if opts.http_only { line.append("; HttpOnly"); }
    if opts.secure { line.append("; Secure"); }
    if same_site.len > 0 { format(line, "; SameSite=", same_site); }
    return append_header(c.response, HEADER_SET_COOKIE, line[..]);
}
