import src.constants.http;
import src.http.headers;
import src.http.request;
import src.app.context;
import src.app.cookies;
import src.app.session_state;
import src.sys.crypto;
import std;
namespace web;

// CSRF protection by the double-submit pattern with an authenticated token (the same shape
// as V's veb.csrf). The token is random text plus a tag only the server can make:
//   token = base64url(nonce32) "." base64url(HMAC-SHA256(secret, "gw-csrf|" || base64url(nonce32)))
// The token is also the value of the CSRF cookie. An unsafe request must echo it in the
// X-CSRF-Token header or in a csrf_token form field. An attacker who can plant a cookie cannot
// make a valid tag, so a planted cookie fails verification.

const CSRF_COOKIE = "gw_csrf";
const CSRF_TAG_LABEL = "gw-csrf|";
const CSRF_FORM_FIELD = "csrf_token";
const HEADER_X_CSRF_TOKEN = "X-CSRF-Token";
const HEADER_ORIGIN = "Origin";
const HEADER_REFERER = "Referer";
const CONTENT_TYPE_FORM_URLENCODED = "application/x-www-form-urlencoded";
const CSRF_NONCE_BYTES = 32;

// Safe methods do not change state, so they never need a token to be accepted.
fn csrf_safe_method(method: const u8[:]) -> bool {
    return method == METHOD_GET || method == METHOD_HEAD || method == METHOD_OPTIONS;
}

// Appends the tag text for a token's nonce text.
fn csrf_tag_text(out: u8[>..]&, secret: const u8[:], nonce_text: const u8[:]) {
    var message: u8[>..] = [];
    message.append(CSRF_TAG_LABEL);
    message.append(nonce_text);
    let tag = hmac_sha256(secret, message[..]);
    base64url_append(out, tag[..]);
}

// Whether a token has the right shape and a tag that this secret produced.
fn csrf_token_valid(token: const u8[:], secret: const u8[:]) -> bool {
    if token.len != CSRF_TOKEN_BYTES || token[BASE64URL_32_BYTES] != '.' { return false; }
    var expected: u8[>..] = [];
    csrf_tag_text(expected, secret, token[..BASE64URL_32_BYTES]);
    return constant_time_equal(expected[..], token[BASE64URL_32_BYTES + 1..]);
}

// Mints a new token, stores it in c.csrf_state and writes the CSRF cookie. False when no
// entropy source is available; nothing is issued in that case.
fn csrf_mint(c: Ctx&, secret: const u8[:]) -> bool {
    var nonce: u8[32] = [0; 32];
    if !random_bytes(nonce[..]) { return false; }
    var nonce_text: u8[>..] = [];
    base64url_append(nonce_text, nonce[..]);
    var token: u8[>..] = [];
    token.append(nonce_text[..]);
    token.push('.');
    csrf_tag_text(token, secret, nonce_text[..]);
    c.csrf_state.token = token[..];
    set_cookie(c, CSRF_COOKIE, token[..]);
    return true;
}

// Form field value from an application/x-www-form-urlencoded body, or "" when the body is
// another type or has no such field. Values are compared as sent, so a token must not be
// percent-encoded (tokens use only URL-safe characters, so clients need not encode them).
fn csrf_form_field(c: Ctx&) -> const u8[:] {
    let content_type = c.header(HEADER_CONTENT_TYPE);
    let semi = find(content_type, ";");
    let media = request_ows(if semi < 0 { content_type } else { content_type[..semi] });
    if !equal_header(media, CONTENT_TYPE_FORM_URLENCODED) { return ""; }
    let body = c.request.body;
    var pos: i64 = 0;
    loop {
        let amp = find(body[pos..], "&");
        let end = if amp < 0 { body.len } else { pos + amp };
        let pair = body[pos..end];
        let equals = find(pair, "=");
        if equals >= 0 && pair[..equals] == CSRF_FORM_FIELD { return pair[equals + 1..]; }
        if amp < 0 { return ""; }
        pos = end + 1;
    }
}

// The token the request submitted: the X-CSRF-Token header, else the csrf_token form field.
fn csrf_submitted(c: Ctx&) -> const u8[:] {
    let header_value = c.header(HEADER_X_CSRF_TOKEN);
    if header_value.len > 0 { return header_value; }
    return csrf_form_field(c);
}

// Host part of an absolute URL (scheme://authority/...), or "" when there is no scheme.
fn url_authority(url: const u8[:]) -> const u8[:] {
    let scheme = find(url, "://");
    if scheme < 0 { return ""; }
    let rest = url[scheme + 3..];
    let slash = find(rest, "/");
    return if slash < 0 { rest } else { rest[..slash] };
}

// Origin check for unsafe requests. An Origin header must name the Host exactly; without it a
// Referer must. A request with neither is allowed here, because the token check still applies.
fn csrf_origin_ok(c: Ctx&) -> bool {
    let host = c.header(HEADER_HOST);
    if host.len == 0 { return false; }
    let origin = c.header(HEADER_ORIGIN);
    if origin.len > 0 {
        let authority = url_authority(origin);
        return authority.len > 0 && equal_header(authority, host);
    }
    let referer = c.header(HEADER_REFERER);
    if referer.len > 0 {
        let authority = url_authority(referer);
        return authority.len > 0 && equal_header(authority, host);
    }
    return true;
}

// CSRF middleware. Safe methods pass through and receive a token cookie when they have none
// (or a forged one). Unsafe methods need a valid cookie token that the request echoes in
// X-CSRF-Token or csrf_token, and, when check_origin is set, a matching Origin or Referer.
// Anything else answers 403 csrf_failed without calling Next.
fn csrf<Next>(c: Ctx&, secret: const u8[:], check_origin: bool) {
    assert(secret.len >= SESSION_MIN_SECRET_BYTES);
    c.csrf_state.active = true;
    let presented = cookie(c, CSRF_COOKIE);
    let cookie_valid = csrf_token_valid(presented, secret);
    if csrf_safe_method(c.method()) {
        if cookie_valid {
            c.csrf_state.token = presented;
        } else if !csrf_mint(c, secret) {
            c.fail(HTTP_INTERNAL_SERVER_ERROR, "entropy_unavailable", "No random source for a CSRF token");
            return;
        }
        Next();
        return;
    }
    let submitted = csrf_submitted(c);
    if !cookie_valid || submitted.len == 0 || !constant_time_equal(submitted, presented) {
        c.fail(HTTP_FORBIDDEN, "csrf_failed", "CSRF token is missing or invalid");
        return;
    }
    if check_origin && !csrf_origin_ok(c) {
        c.fail(HTTP_FORBIDDEN, "csrf_failed", "Origin does not match the request host");
        return;
    }
    c.csrf_state.token = presented;
    Next();
}

// The CSRF token for this request, for forms and templates. "" when no csrf middleware runs.
fn csrf_token(c: Ctx&) -> const u8[:] {
    return c.csrf_state.token[..];
}
