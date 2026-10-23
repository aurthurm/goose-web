// CSRF middleware: safe methods issue a token cookie, unsafe methods accept only a matching
// echo of the cookie token, and the optional Origin check compares against Host.
import goose_web from "../..";
import std;

const SECRET = "fedcba9876543210fedcba9876543210";
const OTHER_SECRET = "fedcba9876543210fedcba987654321z";

// Each context borrows this response; a test finishes with one context before creating the next.
var shared_response = web::response();
var shared_scratch = web::AppScratch { .. };

fn make_ctx(method: const u8[:], target: const u8[:], headers: const u8[:], body: const u8[:]) -> web::Ctx {
    shared_response = web::response();
    return web::new_ctx(web::Request { method: method, target: target, body: body, raw_headers: headers }, shared_response, shared_scratch);
}

// Value of the gw_csrf Set-Cookie line in a response, or "" when there is none.
fn issued_token(res: web::Response&) -> const u8[:] {
    for i in res.headers.len {
        if res.headers[i].name == "Set-Cookie" && find(res.headers[i].value[..], "gw_csrf=") == 0 {
            let line = res.headers[i].value[..];
            return line[8..find(line, ";")];
        }
    }
    return "";
}

// A token minted by the middleware for a safe request, copied out of the response.
fn mint(secret: const u8[:]) -> u8[>..] {
    var issuer = make_ctx("GET", "/form", "Host: x\r\n", "");
    csrf(issuer, secret, false) { };
    var token: u8[>..] = [];
    token.append(issued_token(issuer.response));
    return token;
}

// Request headers: Host, an optional Cookie, and an optional X-CSRF-Token header.
fn headers_for(cookie: const u8[:], header: const u8[:]) -> u8[>..] {
    var headers: u8[>..] = [];
    headers.append("Host: x\r\n");
    if cookie.len > 0 {
        headers.append("Cookie: gw_csrf=");
        headers.append(cookie);
        headers.append("\r\n");
    }
    if header.len > 0 {
        headers.append("X-CSRF-Token: ");
        headers.append(header);
        headers.append("\r\n");
    }
    return headers;
}

fn form_body(text: const u8[:]) -> u8[>..] {
    var body: u8[>..] = [];
    body.append(text);
    return body;
}

fn unsafe_method(index: i64) -> const u8[:] {
    if index == 0 { return "PUT"; }
    if index == 1 { return "PATCH"; }
    if index == 2 { return "DELETE"; }
    return "POST";
}

fn has_forbidden(c: web::Ctx&) -> bool {
    return c.response.status == web::HTTP_FORBIDDEN && find(web::body_of(c.response), "\"csrf_failed\"") > 0;
}

fn test_safe_methods_issue_token() {
    var c = make_ctx("GET", "/form", "Host: x\r\n", "");
    var reached = false;
    csrf(c, SECRET, false) {
        reached = true;
        assert(csrf_token(c).len == 87);
    };
    assert(reached && c.response.status == web::HTTP_OK);
    let issued = issued_token(c.response);
    assert(issued.len == 87 && issued[43] == '.');

    // HEAD and OPTIONS are safe too, and a valid cookie is kept rather than re-issued.
    var token: u8[>..] = [];
    token.append(issued);
    var headers = headers_for(token[..], "");
    var kept = make_ctx("GET", "/form", headers[..], "");
    var kept_reached = false;
    csrf(kept, SECRET, false) {
        kept_reached = true;
        assert(csrf_token(kept) == token[..]);
    };
    assert(kept_reached && issued_token(kept.response).len == 0);

    var head_headers = headers_for("", "");
    var head = make_ctx("HEAD", "/form", head_headers[..], "");
    var head_reached = false;
    csrf(head, SECRET, false) { head_reached = true; };
    assert(head_reached);

    var options = make_ctx("OPTIONS", "/form", head_headers[..], "");
    var options_reached = false;
    csrf(options, SECRET, false) { options_reached = true; };
    assert(options_reached);

    // A forged cookie on a safe request is replaced with a freshly minted token.
    var forged_headers = headers_for("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA.BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB", "");
    var forged = make_ctx("GET", "/form", forged_headers[..], "");
    csrf(forged, SECRET, false) { };
    assert(issued_token(forged.response).len == 87);
}

fn test_unsafe_accept_matrix() {
    let token = mint(SECRET);
    var good_headers = headers_for(token[..], token[..]);

    // Header echo.
    var header_ok = make_ctx("POST", "/items", good_headers[..], "");
    var header_reached = false;
    csrf(header_ok, SECRET, false) { header_reached = true; };
    assert(header_reached && header_ok.response.status == web::HTTP_OK);

    // Form field echo with a form content type.
    var form_headers: u8[>..] = [];
    form_headers.append("Host: x\r\nContent-Type: application/x-www-form-urlencoded; charset=utf-8\r\nCookie: gw_csrf=");
    form_headers.append(token[..]);
    form_headers.append("\r\n");
    var form_body_text = form_body("title=milk&csrf_token=");
    form_body_text.append(token[..]);
    form_body_text.append("&done=1");
    var form_ok = make_ctx("POST", "/items", form_headers[..], form_body_text[..]);
    var form_reached = false;
    csrf(form_ok, SECRET, false) { form_reached = true; };
    assert(form_reached);

    // The same form field under another content type is not read.
    var text_headers: u8[>..] = [];
    text_headers.append("Host: x\r\nContent-Type: text/plain\r\nCookie: gw_csrf=");
    text_headers.append(token[..]);
    text_headers.append("\r\n");
    var text_plain = make_ctx("POST", "/items", text_headers[..], form_body_text[..]);
    csrf(text_plain, SECRET, false) { assert(false); };
    assert(has_forbidden(text_plain));

    // Every unsafe method needs the token.
    for m in 4 {
        var unsafe = make_ctx(unsafe_method(m), "/items/1", good_headers[..], "");
        var unsafe_reached = false;
        csrf(unsafe, SECRET, false) { unsafe_reached = true; };
        assert(unsafe_reached);
    }

    // Refusals: each one 403 csrf_failed, and Next never runs.
    var mismatch_headers = headers_for(token[..], "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA.BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB");
    var mismatch = make_ctx("POST", "/items", mismatch_headers[..], "");
    csrf(mismatch, SECRET, false) { assert(false); };
    assert(has_forbidden(mismatch));

    var missing_echo = headers_for(token[..], "");
    var no_echo = make_ctx("DELETE", "/items/1", missing_echo[..], "");
    csrf(no_echo, SECRET, false) { assert(false); };
    assert(has_forbidden(no_echo));

    var no_cookie = headers_for("", token[..]);
    var cookieless = make_ctx("POST", "/items", no_cookie[..], "");
    csrf(cookieless, SECRET, false) { assert(false); };
    assert(has_forbidden(cookieless));

    var one_off = token[..];
    var flipped: u8[>..] = [];
    flipped.append(one_off);
    flipped[5] = if one_off[5] == 'A' { 'B' } else { 'A' };
    var flipped_headers = headers_for(flipped[..], flipped[..]);
    var flipped_request = make_ctx("POST", "/items", flipped_headers[..], "");
    csrf(flipped_request, SECRET, false) { assert(false); };
    assert(has_forbidden(flipped_request));

    // A token from another secret is a forgery even when cookie and echo agree.
    let foreign = mint(OTHER_SECRET);
    var foreign_headers = headers_for(foreign[..], foreign[..]);
    var foreign_request = make_ctx("POST", "/items", foreign_headers[..], "");
    csrf(foreign_request, SECRET, false) { assert(false); };
    assert(has_forbidden(foreign_request));

    // An empty echo is never a match, even against an empty cookie.
    var empty_headers = headers_for("", "");
    var empty_request = make_ctx("POST", "/items", empty_headers[..], "");
    csrf(empty_request, SECRET, false) { assert(false); };
    assert(has_forbidden(empty_request));
}

fn test_origin_check() {
    let token = mint(SECRET);
    var base: u8[>..] = [];
    base.append("Host: x\r\nCookie: gw_csrf=");
    base.append(token[..]);
    base.append("\r\nX-CSRF-Token: ");
    base.append(token[..]);
    base.append("\r\n");

    // Matching Origin passes; a mismatched Origin is refused only when the check is on.
    var same: u8[>..] = [];
    same.append(base[..]);
    same.append("Origin: https://x\r\n");
    var same_request = make_ctx("POST", "/items", same[..], "");
    var same_reached = false;
    csrf(same_request, SECRET, true) { same_reached = true; };
    assert(same_reached);

    var other: u8[>..] = [];
    other.append(base[..]);
    other.append("Origin: https://evil.example\r\n");
    var other_off = make_ctx("POST", "/items", other[..], "");
    var off_reached = false;
    csrf(other_off, SECRET, false) { off_reached = true; };
    assert(off_reached);
    var other_on = make_ctx("POST", "/items", other[..], "");
    csrf(other_on, SECRET, true) { assert(false); };
    assert(has_forbidden(other_on));

    // Referer stands in when Origin is absent; a missing pair is allowed (the token still applies).
    var referer_bad: u8[>..] = [];
    referer_bad.append(base[..]);
    referer_bad.append("Referer: https://evil.example/page\r\n");
    var referer_request = make_ctx("POST", "/items", referer_bad[..], "");
    csrf(referer_request, SECRET, true) { assert(false); };
    assert(has_forbidden(referer_request));

    var referer_good: u8[>..] = [];
    referer_good.append(base[..]);
    referer_good.append("Referer: https://x/page?q=1\r\n");
    var referer_ok = make_ctx("POST", "/items", referer_good[..], "");
    var referer_reached = false;
    csrf(referer_ok, SECRET, true) { referer_reached = true; };
    assert(referer_reached);

    var bare = make_ctx("POST", "/items", base[..], "");
    var bare_reached = false;
    csrf(bare, SECRET, true) { bare_reached = true; };
    assert(bare_reached);

    // An opaque Origin ("null") has no authority and is refused when the check is on.
    var opaque: u8[>..] = [];
    opaque.append(base[..]);
    opaque.append("Origin: null\r\n");
    var opaque_request = make_ctx("POST", "/items", opaque[..], "");
    csrf(opaque_request, SECRET, true) { assert(false); };
    assert(has_forbidden(opaque_request));
}

fn main() {
    test_safe_methods_issue_token();
    test_unsafe_accept_matrix();
    test_origin_check();
    print("CSRF unit tests passed: token issue, safe methods, header and form echo, refusals, Origin and Referer checks");
}
