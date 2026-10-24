// Authentication helpers: PBKDF2 password hashes, HTTP Basic and Bearer middleware, and signed
// tokens. Known answers were computed with Python hashlib (OpenSSL) and base64 from Python. The
// default iteration count is exercised once; the other cases use 1000 iterations so the debug
// build stays quick.
import goose_web from "../..";
import std;

const SECRET = "0123456789abcdef0123456789abcdef";
const OTHER_SECRET = "fedcba9876543210fedcba9876543210";
// PBKDF2-HMAC-SHA256, "wonderland", salt "0123456789abcdef", 1000 iterations.
const ENCODED = "$pbkdf2-sha256$1000$MDEyMzQ1Njc4OWFiY2RlZg$b0FaKDULMkLlg4NThBeBNEp1S6xlfQTtaZwup0NyE5Q";
// Basic credentials as base64 (standard alphabet): "alice:wonderland", "alice:nope", "bob:wonderland".
const BASIC_GOOD = "YWxpY2U6d29uZGVybGFuZA==";
const BASIC_WRONG_PASSWORD = "YWxpY2U6bm9wZQ==";
const BASIC_WRONG_USER = "Ym9iOndvbmRlcmxhbmQ=";
const BASIC_NO_COLON = "YWxpY2V3b25kZXJsYW5k";

fn check_login(user: const u8[:], password: const u8[:]) -> bool {
    return user == "alice" && web::verify_password(password, ENCODED);
}

fn header_value(res: web::Response&, name: const u8[:]) -> const u8[:] {
    for i in res.headers.len {
        if res.headers[i].name == name { return res.headers[i].value; }
    }
    return "";
}

// Request headers: a Host line and one Authorization line made of scheme and credentials.
fn with_authorization(out: u8[>..]&, scheme: const u8[:], credentials: const u8[:]) {
    out.clear();
    format(out, "Host: x\r\nAuthorization: ", scheme, credentials, "\r\n");
}

// Runs basic_auth for one Authorization value. True when the request was refused with 401 and
// Next did not run; the subject must stay empty in that case.
fn basic_refused(scheme: const u8[:], credentials: const u8[:]) -> bool {
    var raw: u8[>..] = [];
    with_authorization(raw, scheme, credentials);
    var out = web::response();
    var scratch = web::AppScratch { .. };
    var c = web::new_ctx(web::Request { method: "GET", target: "/private", body: "", raw_headers: raw[..] }, out, scratch);
    var reached = false;
    web::basic_auth(c, "Admin", check_login) { reached = true; };
    return !reached && c.response.status == web::HTTP_UNAUTHORIZED && web::auth_subject(c).len == 0;
}

// Runs bearer_auth for one Authorization value; true when Next ran.
fn bearer_reaches(scheme: const u8[:], credentials: const u8[:]) -> bool {
    var raw: u8[>..] = [];
    with_authorization(raw, scheme, credentials);
    var out = web::response();
    var scratch = web::AppScratch { .. };
    var c = web::new_ctx(web::Request { method: "GET", target: "/me", body: "", raw_headers: raw[..] }, out, scratch);
    var reached = false;
    web::bearer_auth(c, SECRET) { reached = true; };
    return reached;
}

fn token_valid(secret: const u8[:], token: const u8[:], now: i64) -> bool {
    let subject, ok = web::verify_token_at(secret, token, now);
    return ok && subject.len > 0;
}

fn test_password_hashing() {
    // Known answer: the stored hash verifies; a wrong or empty password does not.
    assert(web::verify_password("wonderland", ENCODED));
    assert(!web::verify_password("Wonderland", ENCODED));
    assert(!web::verify_password("", ENCODED));

    // Fresh hashes carry the prefix and count, verify, and differ because the salt is random.
    let first, first_ok = web::hash_password_iterations("correct horse", 1000);
    let second, second_ok = web::hash_password_iterations("correct horse", 1000);
    assert(first_ok && second_ok);
    assert(starts_with(first[..], "$pbkdf2-sha256$1000$"));
    assert(web::verify_password("correct horse", first[..]));
    assert(!web::verify_password("correct  horse", first[..]));
    assert(!(first[..] == second[..]));

    // A count outside 1..PASSWORD_MAX_ITERATIONS is refused and writes no hash.
    let none, none_ok = web::hash_password_iterations("x", 0);
    assert(!none_ok && none.len == 0);

    // Malformed, unsupported and over-limit encodings are false, never a crash.
    assert(!web::verify_password("wonderland", "$pbkdf2-sha1$1000$MDEyMzQ1Njc4OWFiY2RlZg$b0FaKDULMkLlg4NThBeBNEp1S6xlfQTtaZwup0NyE5Q"));
    assert(!web::verify_password("wonderland", "$pbkdf2-sha256$01000$MDEyMzQ1Njc4OWFiY2RlZg$b0FaKDULMkLlg4NThBeBNEp1S6xlfQTtaZwup0NyE5Q"));
    assert(!web::verify_password("wonderland", "$pbkdf2-sha256$0$MDEyMzQ1Njc4OWFiY2RlZg$b0FaKDULMkLlg4NThBeBNEp1S6xlfQTtaZwup0NyE5Q"));
    assert(!web::verify_password("wonderland", "$pbkdf2-sha256$10000001$MDEyMzQ1Njc4OWFiY2RlZg$b0FaKDULMkLlg4NThBeBNEp1S6xlfQTtaZwup0NyE5Q"));
    assert(!web::verify_password("wonderland", "$pbkdf2-sha256$1000$MDEyMzQ1$b0FaKDULMkLlg4NThBeBNEp1S6xlfQTtaZwup0NyE5Q"));
    assert(!web::verify_password("wonderland", "$pbkdf2-sha256$1000$MDEyMzQ1Njc4OWFiY2RlZg$b0FaKDULMkLlg4NThBeBNEp1S6xlfQTtaZwup0NyE5"));
    assert(!web::verify_password("wonderland", "$pbkdf2-sha256$1000$MDEyMzQ1Njc4OWFiY2RlZg$b0FaKDULMkLlg4NThBeBNEp1S6xlfQTtaZwup0NyE5Q$"));
    assert(!web::verify_password("wonderland", "$pbkdf2-sha256$1000$MDEyMzQ1Njc4OWFiY2RlZg$b0FaKDULMkLlg+NThBeBNEp1S6xlfQTtaZwup0NyE5Q"));
    assert(!web::verify_password("wonderland", "pbkdf2-sha256$1000$MDEyMzQ1Njc4OWFiY2RlZg$b0FaKDULMkLlg4NThBeBNEp1S6xlfQTtaZwup0NyE5Q"));
    assert(!web::verify_password("wonderland", ""));

    // The default count: 600000 iterations, encoded and verified.
    let default_hash, default_ok = web::hash_password("hunter2");
    assert(default_ok && starts_with(default_hash[..], "$pbkdf2-sha256$600000$"));
    assert(web::verify_password("hunter2", default_hash[..]));
    assert(!web::verify_password("hunter3", default_hash[..]));
}

fn test_standard_base64() {
    // Standard alphabet: '+' and '/' decode; the URL-safe spellings are refused; padding must be exact.
    var decoded: u8[>..] = [];
    assert(web::base64_standard_decode(decoded, "+/8="));
    assert(decoded.len == 2 && decoded[0] == 0xfb && decoded[1] == 0xff);
    decoded.clear();
    assert(!web::base64_standard_decode(decoded, "-_8="));
    assert(!web::base64_standard_decode(decoded, "+/8=="));
    assert(!web::base64_standard_decode(decoded, "+/8=x"));
    assert(decoded.len == 0);
}

fn test_basic_auth() {
    // No Authorization header: 401 with the Basic challenge, and Next does not run.
    var reached = false;
    var out = web::response();
    var scratch = web::AppScratch { .. };
    var c = web::new_ctx(web::Request { method: "GET", target: "/private", body: "", raw_headers: "Host: x\r\n" }, out, scratch);
    web::basic_auth(c, "Admin", check_login) { reached = true; };
    assert(!reached && c.response.status == web::HTTP_UNAUTHORIZED);
    assert(header_value(c.response, "WWW-Authenticate") == "Basic realm=\"Admin\", charset=\"UTF-8\"");
    assert(find(web::body_of(c.response), "\"code\":\"unauthorized\"") >= 0);
    assert(web::auth_subject(c).len == 0);

    // Valid credentials: Next runs, and the verified subject is available to it.
    var raw: u8[>..] = [];
    with_authorization(raw, "Basic ", BASIC_GOOD);
    var good_out = web::response();
    var good_scratch = web::AppScratch { .. };
    var good = web::new_ctx(web::Request { method: "GET", target: "/private", body: "", raw_headers: raw[..] }, good_out, good_scratch);
    var subject_seen: u8[>..] = [];
    good.basic_auth("Admin", check_login) {
        reached = true;
        subject_seen.append(good.auth_subject());
        good.text("inside");
    };
    assert(reached && subject_seen[..] == "alice");
    assert(good.response.status == web::HTTP_OK && web::body_of(good.response) == "inside");

    // A wrong password, a wrong user, a missing colon, another scheme, invalid base64, and bare
    // or empty scheme text all answer 401 without running Next.
    assert(basic_refused("Basic ", BASIC_WRONG_PASSWORD));
    assert(basic_refused("Basic ", BASIC_WRONG_USER));
    assert(basic_refused("Basic ", BASIC_NO_COLON));
    assert(basic_refused("Bearer ", BASIC_GOOD));
    assert(basic_refused("Basic ", "!!!"));
    assert(basic_refused("Basic ", ""));
    assert(basic_refused("Basicx ", BASIC_GOOD));
}

fn test_bearer_auth() {
    // A token signed for alice, 300 seconds: accepted, and the subject is available.
    let token, token_ok = web::sign_token(SECRET, "alice", 300);
    assert(token_ok && token.len <= 256);
    var raw: u8[>..] = [];
    with_authorization(raw, "Bearer ", token[..]);
    var out = web::response();
    var scratch = web::AppScratch { .. };
    var c = web::new_ctx(web::Request { method: "GET", target: "/me", body: "", raw_headers: raw[..] }, out, scratch);
    var reached = false;
    c.bearer_auth(SECRET) {
        reached = true;
        c.text(c.auth_subject());
    };
    assert(reached && web::body_of(c.response) == "alice");

    // The scheme is case-insensitive.
    assert(bearer_reaches("bearer ", token[..]));

    // No token: 401 with a bare Bearer challenge.
    var none_out = web::response();
    var none_scratch = web::AppScratch { .. };
    var none = web::new_ctx(web::Request { method: "GET", target: "/me", body: "", raw_headers: "Host: x\r\n" }, none_out, none_scratch);
    reached = false;
    web::bearer_auth(none, SECRET) { reached = true; };
    assert(!reached && none.response.status == web::HTTP_UNAUTHORIZED);
    assert(header_value(none.response, "WWW-Authenticate") == "Bearer");

    // A tampered token is refused with invalid_token.
    var edited: u8[>..] = [];
    edited.append(token[..]);
    edited[0] = if edited[0] == 'A' { 'B' } else { 'A' };
    with_authorization(raw, "Bearer ", edited[..]);
    var bad_out = web::response();
    var bad_scratch = web::AppScratch { .. };
    var bad = web::new_ctx(web::Request { method: "GET", target: "/me", body: "", raw_headers: raw[..] }, bad_out, bad_scratch);
    reached = false;
    web::bearer_auth(bad, SECRET) { reached = true; };
    assert(!reached && bad.response.status == web::HTTP_UNAUTHORIZED);
    assert(header_value(bad.response, "WWW-Authenticate") == "Bearer error=\"invalid_token\"");

    // A token signed under another secret is refused.
    let forged, forged_ok = web::sign_token(OTHER_SECRET, "alice", 300);
    assert(forged_ok);
    assert(!bearer_reaches("Bearer ", forged[..]));

    // The "none" pattern: the same payload with its tag removed must never verify.
    let dot = find(token[..], ".");
    assert(dot > 0);
    var unsigned: u8[>..] = [];
    unsigned.append(token[..dot + 1]);
    assert(!bearer_reaches("Bearer ", unsigned[..]));
}

fn test_tokens() {
    let now = web::unix_seconds();
    assert(now > 0);
    let token, ok = web::sign_token(SECRET, "alice", 60);
    assert(ok);
    let subject, valid = web::verify_token_at(SECRET, token[..], now);
    assert(valid && subject[..] == "alice");
    // Expired one second past the ttl, and refused when issued an hour before the check time.
    let late, late_ok = web::verify_token_at(SECRET, token[..], now + 61);
    assert(!late_ok && late.len == 0);
    assert(!token_valid(SECRET, token[..], now - 3600));

    // Signing refuses a short secret, an empty or oversize subject, and a ttl outside 1..max.
    let short, short_ok = web::sign_token("too short", "alice", 60);
    assert(!short_ok && short.len == 0);
    let empty, empty_ok = web::sign_token(SECRET, "", 60);
    assert(!empty_ok && empty.len == 0);
    var long_subject: u8[>..] = [];
    long_subject.resize(65, 'a');
    let long, long_ok = web::sign_token(SECRET, long_subject[..], 60);
    assert(!long_ok && long.len == 0);
    let zero, zero_ok = web::sign_token(SECRET, "alice", 0);
    assert(!zero_ok && zero.len == 0);
    let forever, forever_ok = web::sign_token(SECRET, "alice", 315360001);
    assert(!forever_ok && forever.len == 0);

    // The longest subject, 64 bytes, round-trips.
    var full_subject: u8[>..] = [];
    full_subject.resize(64, 'z');
    let full, full_ok = web::sign_token(SECRET, full_subject[..], 60);
    assert(full_ok);
    let full_back, full_valid = web::verify_token_at(SECRET, full[..], now);
    assert(full_valid && full_back[..] == full_subject[..]);

    // Shape and tag checks: a second dot, an empty tag, a truncated tag, a short verifier secret,
    // empty input, and a zero clock all fail.
    var doubled: u8[>..] = [];
    doubled.append(token[..]);
    doubled.append(".");
    assert(!token_valid(SECRET, doubled[..], now));
    let dot = find(token[..], ".");
    var untagged: u8[>..] = [];
    untagged.append(token[..dot + 1]);
    assert(!token_valid(SECRET, untagged[..], now));
    assert(!token_valid(SECRET, token[..token.len - 1], now));
    assert(!token_valid("too short", token[..], now));
    assert(!token_valid(SECRET, "", now));
    assert(!token_valid(SECRET, token[..], 0));
}

fn main() {
    test_password_hashing();
    test_standard_base64();
    test_basic_auth();
    test_bearer_auth();
    test_tokens();
    print("Auth tests passed: PBKDF2 known answer and limits, Basic and Bearer middleware, signed token expiry, tampering and secret checks");
}
