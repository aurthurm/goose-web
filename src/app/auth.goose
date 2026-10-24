import src.constants.http;
import src.constants.limits;
import src.http.headers;
import src.http.request;
import src.app.context;
import src.app.session_state;
import src.sys.crypto;
import src.sys.process;
import std;
namespace web;

// Authentication helpers: password hashing, HTTP Basic and Bearer middleware, and HMAC-signed
// tokens. Everything here is built on native/posix/crypto.c and the session/CSRF primitives.
//
// Password hashes use PBKDF2-HMAC-SHA256 (RFC 8018) in this encoded form:
//   $pbkdf2-sha256$<iterations>$<salt base64url>$<hash base64url>
// The salt is 16 random bytes and the hash 32 bytes, both unpadded base64url. The default is
// 600000 iterations (OWASP's 2023 guidance for PBKDF2-HMAC-SHA256); hash_password_iterations
// chooses another count. verify_password reads the count from the hash, so older hashes keep
// working after a change.
//
// Tokens are not JWTs. A JWT names its algorithm in a header, and a verifier that trusts that
// name can be talked into "alg": "none" or into a public-key check done with a shared secret.
// Here there is no algorithm field: the format is fixed to HMAC-SHA256 under one secret, so no
// header can change how a token is checked. The text is
//   base64url(payload) "." base64url(tag)     tag = HMAC-SHA256(secret, "gw-token|" || base64url(payload))
// payload = version (1 byte, 1) | issued (8 bytes, big-endian Unix seconds) |
//           expires (8 bytes, big-endian Unix seconds) | subject (the rest, 1 to 64 bytes)
// Tokens are bearer credentials: anyone holding one can use it until it expires. There is no
// revocation; keep ttl short, or rotate the secret to sign everyone out.

const PASSWORD_HASH_PREFIX = "$pbkdf2-sha256$";
// Bytes in PASSWORD_HASH_PREFIX.
const PASSWORD_HASH_PREFIX_BYTES = 15;
const PASSWORD_DEFAULT_ITERATIONS = 600000;
// Verification refuses hashes above this count, so an attacker-supplied stored hash cannot cost
// unbounded CPU.
const PASSWORD_MAX_ITERATIONS = 10000000;
const PASSWORD_SALT_BYTES = 16;
const PASSWORD_MIN_SALT_BYTES = 16;
const PASSWORD_MAX_SALT_BYTES = 64;
const PASSWORD_HASH_BYTES = 32;
// Base64url of the 32-byte hash, unpadded.
const PASSWORD_HASH_TEXT_BYTES = 43;
const PASSWORD_ENCODED_MAX_BYTES = 128;

const TOKEN_VERSION = 1;
// Version, issue time and expiry.
const TOKEN_HEADER_BYTES = 17;
const TOKEN_LABEL = "gw-token|";
const TOKEN_MAX_TTL_SECONDS = 315360000;
const TOKEN_MAX_TEXT_BYTES = 256;

const AUTH_SCHEME_BASIC = "Basic";
const AUTH_SCHEME_BEARER = "Bearer";
// Longest Authorization credentials accepted before decoding, so a huge header costs nothing.
const AUTH_CREDENTIALS_MAX_TEXT_BYTES = 512;
const AUTH_REALM_MAX_BYTES = 128;

// Hashes password with the default iteration count. The result is the encoded text
// (PASSWORD_HASH_PREFIX form) and true, or an empty value and false when no random source
// answers. Store the whole text; it carries the salt and the count.
fn hash_password(password: const u8[:]) -> u8[..128], bool {
    let encoded, ok = hash_password_iterations(password, PASSWORD_DEFAULT_ITERATIONS);
    return encoded, ok;
}

// As hash_password with an explicit iteration count, 1 to PASSWORD_MAX_ITERATIONS. Counts below
// the default weaken the hash; use them only for tests.
fn hash_password_iterations(password: const u8[:], iterations: i64) -> u8[..128], bool {
    var encoded: u8[..128] = "";
    if iterations < 1 || iterations > PASSWORD_MAX_ITERATIONS { return encoded, false; }
    var salt: u8[16] = [0; 16];
    if !random_bytes(salt[..]) { return encoded, false; }
    var derived: u8[32] = [0; 32];
    if !pbkdf2_sha256(password, salt[..], iterations, derived[..]) { return encoded, false; }
    var text: u8[>..] = [];
    format(text, PASSWORD_HASH_PREFIX, iterations, "$");
    base64url_append(text, salt[..]);
    text.push('$');
    base64url_append(text, derived[..]);
    encoded.append(text[..]);
    return encoded, true;
}

// True when password matches the encoded hash. The derived key is compared in constant time.
// A malformed, unsupported or over-limit encoding is false without any derivation. Only the
// comparison is secret-dependent: the format and count are public.
fn verify_password(password: const u8[:], encoded: const u8[:]) -> bool {
    if encoded.len > PASSWORD_ENCODED_MAX_BYTES || !starts_with(encoded, PASSWORD_HASH_PREFIX) { return false; }
    let rest = encoded[PASSWORD_HASH_PREFIX_BYTES..];
    let count_end = find(rest, "$");
    if count_end <= 0 { return false; }
    let iterations, count_ok = parse_canonical(rest[..count_end]);
    if !count_ok || iterations < 1 || iterations > PASSWORD_MAX_ITERATIONS { return false; }
    let after = rest[count_end + 1..];
    let salt_end = find(after, "$");
    if salt_end < 0 { return false; }
    let salt_text = after[..salt_end];
    let hash_text = after[salt_end + 1..];
    if hash_text.len != PASSWORD_HASH_TEXT_BYTES { return false; }
    var salt: u8[>..] = [];
    if !base64url_decode(salt, salt_text) { return false; }
    if salt.len < PASSWORD_MIN_SALT_BYTES || salt.len > PASSWORD_MAX_SALT_BYTES { return false; }
    var expected: u8[>..] = [];
    if !base64url_decode(expected, hash_text) || expected.len != PASSWORD_HASH_BYTES { return false; }
    var derived: u8[32] = [0; 32];
    if !pbkdf2_sha256(password, salt[..], iterations, derived[..]) { return false; }
    return constant_time_equal(derived[..], expected[..]);
}

// --- HTTP Basic ---------------------------------------------------------------------

// Standard base64 (RFC 4648 section 4), padded or not, decoded through the URL-safe decoder: '+'
// and '/' are mapped to '-' and '_'. Those two characters are refused in their URL-safe form, so
// each credential has one spelling. Padding is accepted only at the end, and only to a multiple
// of four.
fn base64_standard_decode(out: u8[>..]&, src: const u8[:]) -> bool {
    var body = src;
    var padding: i64 = 0;
    while body.len > 0 && body[body.len - 1] == '=' && padding < 2 {
        body = body[..body.len - 1];
        padding += 1;
    }
    if padding > 0 && src.len % 4 != 0 { return false; }
    var url: u8[>..] = [];
    for ch in body {
        if ch == '+' { url.push('-'); }
        else if ch == '/' { url.push('_'); }
        else if ch == '-' || ch == '_' { return false; }
        else { url.push(ch); }
    }
    return base64url_decode(out, url[..]);
}

// Realm text for WWW-Authenticate: printable, without the quote and backslash that would end or
// escape the quoted string.
fn auth_realm_valid(realm: const u8[:]) -> bool {
    if realm.len == 0 || realm.len > AUTH_REALM_MAX_BYTES { return false; }
    for ch in realm {
        if ch < 32 || ch >= 127 || ch == '"' || ch == '\\' { return false; }
    }
    return true;
}

// The Basic credentials decoded into `decoded` ("user:password"). False when the header is
// absent, names another scheme, or is not valid base64.
fn basic_decode(c: Ctx&, decoded: u8[>..]&) -> bool {
    let header = c.header(HEADER_AUTHORIZATION);
    let scheme_end = find(header, " ");
    if scheme_end <= 0 || !equal_header(header[..scheme_end], AUTH_SCHEME_BASIC) { return false; }
    let credentials = request_ows(header[scheme_end + 1..]);
    if credentials.len == 0 || credentials.len > AUTH_CREDENTIALS_MAX_TEXT_BYTES { return false; }
    return base64_standard_decode(decoded, credentials);
}

// 401 with the Basic challenge for realm. The response is a JSON error like every other one.
fn basic_challenge(c: Ctx&, realm: const u8[:]) {
    var challenge: u8[>..] = [];
    format(challenge, AUTH_SCHEME_BASIC, " realm=\"", realm, "\", charset=\"UTF-8\"");
    c.set(HEADER_WWW_AUTHENTICATE, challenge[..]);
    c.fail(HTTP_UNAUTHORIZED, "unauthorized", "Authentication required");
}

// HTTP Basic authentication (RFC 7617). The middleware reads the Authorization header, splits
// "user:password" at the first ':' and calls the named check function
//   fn check_user(user: const u8[:], password: const u8[:]) -> bool
// (passed after realm; see the example in docs/api.md). When the check returns true, the user is
// stored for auth_subject(c) and Next runs. Otherwise the response is 401 with a WWW-Authenticate
// challenge, and Next does not run. The check should verify with verify_password, which compares
// in constant time; the user lookup itself may return early, so missing and wrong users can
// take different times.
fn basic_auth<Check: fn(const u8[:], const u8[:]) -> bool, Next>(c: Ctx&, realm: const u8[:]) {
    assert(auth_realm_valid(realm));
    var decoded: u8[>..] = [];
    if basic_decode(c, decoded) {
        let all = decoded[..];
        let colon = find(all, ":");
        if colon >= 0 {
            let user = all[..colon];
            let password = all[colon + 1..];
            if user.len > 0 && user.len <= AUTH_SUBJECT_MAX_BYTES && Check(user, password) {
                c.auth_state.subject = user;
                Next();
                return;
            }
        }
    }
    basic_challenge(c, realm);
}

// --- Bearer and signed tokens --------------------------------------------------------

// Bearer token from `Authorization: Bearer <token>` (scheme compared case-insensitively), or ""
// when the header is absent or names another scheme. The token is not checked here.
fn bearer_token(c: Ctx&) -> const u8[:] {
    let header = c.header(HEADER_AUTHORIZATION);
    let scheme_end = find(header, " ");
    if scheme_end <= 0 || !equal_header(header[..scheme_end], AUTH_SCHEME_BEARER) { return ""; }
    return request_ows(header[scheme_end + 1..]);
}

// Appends the tag text for a token's payload text under the token label.
fn token_tag_text(out: u8[>..]&, secret: const u8[:], payload_text: const u8[:]) {
    var message: u8[>..] = [];
    message.append(TOKEN_LABEL);
    message.append(payload_text);
    let tag = hmac_sha256(secret, message[..]);
    base64url_append(out, tag[..]);
}

fn token_put_u64(out: u8[>..]&, value: i64) {
    for i in 8 {
        out.push(((value >> (56 - 8 * i)) & 255) as u8);
    }
}

// Signs subject for ttl seconds from now. The token is base64url(payload) "." base64url(tag), as
// described at the top of this file. False, with an empty token, when the secret is shorter than
// SESSION_MIN_SECRET_BYTES, the subject is empty or over AUTH_SUBJECT_MAX_BYTES, ttl is not in
// 1..TOKEN_MAX_TTL_SECONDS, or the clock is unavailable.
fn sign_token(secret: const u8[:], subject: const u8[:], ttl: i64) -> u8[..256], bool {
    var token: u8[..256] = "";
    let now = unix_seconds();
    if secret.len < SESSION_MIN_SECRET_BYTES || subject.len == 0 || subject.len > AUTH_SUBJECT_MAX_BYTES { return token, false; }
    if ttl < 1 || ttl > TOKEN_MAX_TTL_SECONDS || now <= 0 { return token, false; }
    var payload: u8[>..] = [];
    payload.push(TOKEN_VERSION as u8);
    token_put_u64(payload, now);
    token_put_u64(payload, now + ttl);
    payload.append(subject);
    var text: u8[>..] = [];
    base64url_append(text, payload[..]);
    var tag: u8[>..] = [];
    token_tag_text(tag, secret, text[..]);
    token.append(text[..]);
    token.append(".");
    token.append(tag[..]);
    return token, true;
}

// Checks token at time now (Unix seconds) and returns its subject. False when the shape, tag,
// version, times or subject are wrong, or the token is expired, or it was issued more than
// SESSION_CLOCK_SKEW_SECONDS in the future. The tag is compared in constant time before the
// payload is read.
fn verify_token_at(secret: const u8[:], token: const u8[:], now: i64) -> u8[..64], bool {
    var subject: u8[..64] = "";
    if secret.len < SESSION_MIN_SECRET_BYTES || token.len == 0 || token.len > TOKEN_MAX_TEXT_BYTES || now <= 0 {
        return subject, false;
    }
    let dot = find(token, ".");
    if dot <= 0 || find(token[dot + 1..], ".") >= 0 { return subject, false; }
    let text = token[..dot];
    let tag = token[dot + 1..];
    var expected: u8[>..] = [];
    token_tag_text(expected, secret, text);
    if !constant_time_equal(expected[..], tag) { return subject, false; }
    var payload: u8[>..] = [];
    if !base64url_decode(payload, text) { return subject, false; }
    let subject_len = payload.len - TOKEN_HEADER_BYTES;
    if subject_len < 1 || subject_len > AUTH_SUBJECT_MAX_BYTES { return subject, false; }
    if payload[0] != TOKEN_VERSION { return subject, false; }
    // Both times must fit a non-negative i64, so their top bytes are below 128.
    if payload[1] >= 128 || payload[9] >= 128 { return subject, false; }
    var issued: i64 = 0;
    for i in 8 { issued = issued * 256 + payload[1 + i]; }
    var expires: i64 = 0;
    for i in 8 { expires = expires * 256 + payload[9 + i]; }
    if issued > now + SESSION_CLOCK_SKEW_SECONDS || expires <= issued || now >= expires { return subject, false; }
    subject.append(payload[TOKEN_HEADER_BYTES..]);
    return subject, true;
}

// verify_token_at with the current wall-clock time.
fn verify_token(secret: const u8[:], token: const u8[:]) -> u8[..64], bool {
    return verify_token_at(secret, token, unix_seconds());
}

// Bearer authentication. The middleware takes the token from the Authorization header, verifies
// it with verify_token under secret, and on success stores the subject for auth_subject(c) and
// runs Next. Otherwise the response is 401 with a Bearer challenge, and Next does not run.
fn bearer_auth<Next>(c: Ctx&, secret: const u8[:]) {
    assert(secret.len >= SESSION_MIN_SECRET_BYTES);
    let token = bearer_token(c);
    let subject, ok = verify_token(secret, token);
    if ok {
        c.auth_state.subject = subject[..];
        Next();
        return;
    }
    if token.len == 0 {
        c.set(HEADER_WWW_AUTHENTICATE, AUTH_SCHEME_BEARER);
    } else {
        c.set(HEADER_WWW_AUTHENTICATE, "Bearer error=\"invalid_token\"");
    }
    c.fail(HTTP_UNAUTHORIZED, "unauthorized", "A valid bearer token is required");
}

// The subject of the request, set by basic_auth or bearer_auth after verification. "" when no
// verifying middleware ran or it refused the request.
fn auth_subject(c: Ctx&) -> const u8[:] {
    return c.auth_state.subject[..];
}
