// Crypto wrappers and signed cookie sessions: the round trip through the Set-Cookie line,
// tampering, expiry, configuration checks and the size bounds of the store.
import goose_web from "../..";
import std;

// 32 bytes, the minimum secret. The other secret differs in one byte.
const SECRET = "0123456789abcdef0123456789abcdef";
const OTHER_SECRET = "0123456789abcdef0123456789abcdeg";

// Each context borrows this response; a test finishes with one context before creating the next.
var shared_response = web::response();
var shared_scratch = web::AppScratch { .. };

fn make_ctx(method: const u8[:], target: const u8[:], headers: const u8[:], body: const u8[:]) -> web::Ctx {
    shared_response = web::response();
    return web::new_ctx(web::Request { method: method, target: target, body: body, raw_headers: headers }, shared_response, shared_scratch);
}

fn config() -> web::SessionConfig {
    return web::SessionConfig { secret: SECRET };
}

// Value of a "name=value; attributes" line.
fn value_of(line: const u8[:]) -> const u8[:] {
    let equals = find(line, "=");
    let semi = find(line, ";");
    return line[equals + 1..semi];
}

// Cookie header line for a request carrying `value` under the default session name.
fn cookie_headers(value: const u8[:]) -> u8[>..] {
    var headers: u8[>..] = [];
    headers.append("Host: x\r\nCookie: gw_session=");
    headers.append(value);
    headers.append("\r\n");
    return headers;
}

fn test_crypto_wrappers() {
    // FIPS 180-4 "abc" digest starts ba 78 16 bf and ends 15 ad.
    let digest = web::sha256("abc");
    assert(digest[0] == 0xba && digest[1] == 0x78 && digest[31] == 0xad);
    // RFC 4231 test case 2 (the native suite checks every byte).
    let tag = web::hmac_sha256("Jefe", "what do ya want for nothing?");
    assert(tag[0] == 0x5b && tag[1] == 0xdc && tag[31] == 0x43);

    var text: u8[>..] = [];
    web::base64url_append(text, "foobar");
    assert(text == "Zm9vYmFy");
    var back: u8[>..] = [];
    assert(web::base64url_decode(back, text[..]) && back == "foobar");
    var rejected: u8[>..] = [];
    assert(!web::base64url_decode(rejected, "Zg==") && rejected.len == 0);
    assert(!web::base64url_decode(rejected, "Zh") && rejected.len == 0);

    assert(web::constant_time_equal("token", "token") && !web::constant_time_equal("token", "tokem"));
    assert(!web::constant_time_equal("token", "toke"));

    var first: u8[32] = [0; 32];
    var second: u8[32] = [0; 32];
    assert(web::random_bytes(first[..]) && web::random_bytes(second[..]));
    assert(first != second);
}

fn test_config_checks() {
    assert(web::session_config_valid(config()));
    assert(!web::session_config_valid(web::SessionConfig { secret: "short" }));
    assert(!web::session_config_valid(web::SessionConfig { secret: SECRET, max_age: 0 }));
    assert(!web::session_config_valid(web::SessionConfig { secret: SECRET, same_site: "Bogus" }));
    assert(!web::session_config_valid(web::SessionConfig { secret: SECRET, same_site: "None" }));
    assert(web::session_config_valid(web::SessionConfig { secret: SECRET, same_site: "None", secure: true }));
    assert(!web::session_config_valid(web::SessionConfig { secret: SECRET, cookie: "bad name" }));
}

fn test_round_trip() {
    var c = make_ctx("GET", "/", "Host: x\r\n", "");
    session(c, config()) {
        assert(session_get(c, "user") == "");
        assert(session_set(c, "user", "alice"));
        assert(session_set(c, "theme", "dark"));
        assert(session_get(c, "user") == "alice");
        assert(!session_set(c, "", "empty key"));
    };
    let line = shared_response.set_cookie_line[..];
    assert(find(line, "gw_session=") == 0);
    assert(find(line, "; Path=/; Max-Age=86400; HttpOnly; SameSite=Lax") > 0);
    var token: u8[>..] = [];
    token.append(value_of(line));

    // The next request presents the cookie: the store loads and nothing changed, so no Set-Cookie.
    var headers = cookie_headers(token[..]);
    shared_response = web::response();
    var again = make_ctx("GET", "/", headers[..], "");
    session(again, config()) {
        assert(session_get(again, "user") == "alice");
        assert(session_get(again, "theme") == "dark");
        assert(session_get(again, "missing") == "");
        assert(session_set(again, "theme", "dark"));
    };
    assert(shared_response.set_cookie_line.len == 0);

    // Changing a value re-issues the cookie with a fresh tag.
    var changer = make_ctx("GET", "/", headers[..], "");
    session(changer, config()) {
        assert(session_set(changer, "theme", "light"));
    };
    assert(shared_response.set_cookie_line.len > 0);
    assert(value_of(shared_response.set_cookie_line[..]) != token[..]);
}

fn test_clear_expires_cookie() {
    var c = make_ctx("GET", "/", "Host: x\r\n", "");
    session(c, config()) {
        assert(session_set(c, "user", "alice"));
    };
    var token: u8[>..] = [];
    token.append(value_of(shared_response.set_cookie_line[..]));
    var headers = cookie_headers(token[..]);
    var logout = make_ctx("POST", "/logout", headers[..], "");
    session(logout, config()) {
        session_clear(logout);
        assert(session_get(logout, "user") == "");
    };
    assert(find(shared_response.set_cookie_line[..], "gw_session=; Path=/; Max-Age=0") == 0);
}

// A request carrying `value` as the session cookie must see an empty store and no Set-Cookie.
fn expect_empty_session(value: const u8[:], secret: const u8[:]) {
    var headers = cookie_headers(value);
    var bad = make_ctx("GET", "/", headers[..], "");
    session(bad, web::SessionConfig { secret: secret }) {
        assert(session_get(bad, "user") == "");
    };
    assert(shared_response.set_cookie_line.len == 0);
}

fn test_tampering_gives_empty_session() {
    var c = make_ctx("GET", "/", "Host: x\r\n", "");
    session(c, config()) {
        assert(session_set(c, "user", "alice"));
    };
    var genuine: u8[>..] = [];
    genuine.append(value_of(shared_response.set_cookie_line[..]));
    let last = genuine.len - 1;
    let dot = find(genuine[..], ".");

    // A changed payload character, a changed tag character, a dropped dot, and no dot at all.
    var payload_flip: u8[>..] = [];
    payload_flip.append(genuine[..]);
    payload_flip[0] = if genuine[0] == 'A' { 'B' } else { 'A' };
    var tag_flip: u8[>..] = [];
    tag_flip.append(genuine[..]);
    tag_flip[last] = if genuine[last] == 'A' { 'B' } else { 'A' };
    var dotless: u8[>..] = [];
    dotless.append(genuine[..dot]);
    dotless.append(genuine[dot + 1..]);
    expect_empty_session(payload_flip[..], SECRET);
    expect_empty_session(tag_flip[..], SECRET);
    expect_empty_session(dotless[..], SECRET);
    expect_empty_session("garbage", SECRET);
    expect_empty_session("", SECRET);

    // The genuine cookie read with a different secret is forged.
    expect_empty_session(genuine[..], OTHER_SECRET);
}

fn test_expiry_and_clock_skew() {
    var c = make_ctx("GET", "/", "Host: x\r\n", "");
    let before = web::unix_seconds();
    session(c, config()) {
        assert(session_set(c, "user", "alice"));
    };
    var token: u8[>..] = [];
    token.append(value_of(shared_response.set_cookie_line[..]));
    let after = web::unix_seconds();
    assert(before > 1577836800 && after >= before);

    var probe = make_ctx("GET", "/", "Host: x\r\n", "");
    // Within max_age of issue: accepted.
    assert(web::session_load(probe, SECRET, token[..], before, 100));
    assert(probe.session_state.count == 1);
    // At or after issue + max_age: expired and empty.
    assert(!web::session_load(probe, SECRET, token[..], before + 100 + (after - before) + 1, 100));
    assert(probe.session_state.count == 0);
    // Issued more than the clock skew allowance in the future: refused.
    assert(!web::session_load(probe, SECRET, token[..], before - 1000, 100));
    assert(probe.session_state.count == 0);
    // A dead clock never authenticates.
    assert(!web::session_load(probe, SECRET, token[..], 0, 100));
}

fn test_size_limits() {
    var c = make_ctx("GET", "/", "Host: x\r\n", "");
    var big: u8[>..] = [];
    big.resize(256, 'v');
    var too_big: u8[>..] = [];
    too_big.resize(257, 'v');
    var long_key: u8[>..] = [];
    long_key.resize(33, 'k');
    session(c, config()) {
        assert(!session_set(c, long_key[..], "x"));
        assert(!session_set(c, "k", too_big[..]));
        // Ten 256-byte values fit the payload bound; an eleventh does not.
        for i in 10 {
            var key: u8[>..] = [];
            format(key, "k", i);
            assert(session_set(c, key[..], big[..]));
        }
        assert(!session_set(c, "kA", big[..]));
        assert(session_set(c, "kA", "x"));
        assert(c.session_state.count == 11);
    };
    let line = shared_response.set_cookie_line[..];
    assert(line.len > 0 && line.len <= 4096);

    // Sixteen entries is the count limit.
    var d = make_ctx("GET", "/", "Host: x\r\n", "");
    session(d, config()) {
        for i in 16 {
            var key: u8[>..] = [];
            format(key, "n", i);
            assert(session_set(d, key[..], "1"));
        }
        assert(!session_set(d, "overflow", "1"));
    };

    // A cookie longer than 4096 bytes is never read.
    var huge: u8[>..] = [];
    huge.resize(4097, 'a');
    var e = make_ctx("GET", "/", "Host: x\r\n", "");
    assert(!web::session_load(e, SECRET, huge[..], 1, 100));
}

fn test_without_middleware() {
    var c = make_ctx("GET", "/", "Host: x\r\n", "");
    assert(session_get(c, "user") == "");
    assert(!session_set(c, "user", "alice"));
    session_clear(c);
    assert(shared_response.set_cookie_line.len == 0);
}

fn main() {
    test_crypto_wrappers();
    test_config_checks();
    test_round_trip();
    test_clear_expires_cookie();
    test_tampering_gives_empty_session();
    test_expiry_and_clock_skew();
    test_size_limits();
    test_without_middleware();
    print("Session and crypto unit tests passed: SHA-256, HMAC, base64url, round trip, tampering, expiry, size limits");
}
