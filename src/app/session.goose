import src.constants.http;
import src.constants.limits;
import src.http.headers;
import src.app.context;
import src.app.cookies;
import src.app.session_state;
import src.sys.crypto;
import src.sys.process;
import std;
namespace web;

// Signed cookie sessions: a small key/value store carried in the client's cookie and
// authenticated with HMAC-SHA256. The payload is signed, not encrypted: the client can read
// every key and value, and must not be trusted to keep them secret.
//
// Cookie value:  base64url(payload) "." base64url(tag)
//   tag = HMAC-SHA256(secret, "gw-session|" || base64url(payload))
// Payload, before base64url (integers big-endian):
//   version (1 byte, 1) | issued-at Unix seconds (8 bytes) | entry count (1 byte) |
//   per entry: key length (1 byte), key, value length (2 bytes), value
// The issue time is refreshed whenever the store changes. The cookie expires max_age seconds
// after its issue time, and the server refuses it at that moment too.

struct SessionConfig {
    secret: const u8[:],
    cookie: u8[..32] = "gw_session",
    max_age: i64 = 86400,
    secure: bool = false,
    same_site: u8[..8] = "Lax",
}

const SESSION_PAYLOAD_VERSION = 1;
// Version, issue time and entry count.
const SESSION_HEADER_BYTES = 10;
// Key length, value length and the entry count are fixed-width fields of each entry.
const SESSION_ENTRY_OVERHEAD_BYTES = 3;
const SESSION_TAG_LABEL = "gw-session|";

// Whether a config can be honoured. The middleware asserts this: a short secret or an
// impossible attribute is a defect in the application, not a client error.
fn session_config_valid(config: SessionConfig) -> bool {
    if config.secret.len < SESSION_MIN_SECRET_BYTES { return false; }
    if config.cookie.len == 0 || !token(config.cookie[..]) { return false; }
    if config.max_age <= 0 { return false; }
    let same_site, ok = cookie_same_site(config.same_site[..]);
    if !ok || same_site.len == 0 { return false; }
    return !(equal_header(same_site, "None") && !config.secure);
}

// Bytes the payload occupies for the current entries.
fn session_payload_size(c: Ctx&) -> i64 {
    var total: i64 = SESSION_HEADER_BYTES;
    for i in c.session_state.count {
        total += SESSION_ENTRY_OVERHEAD_BYTES + c.session_state.entries[i].key.len + c.session_state.entries[i].value.len;
    }
    return total;
}

// Appends the payload bytes for the current entries, issued at `issued`.
fn session_write_payload(c: Ctx&, out: u8[>..]&, issued: i64) {
    out.push(SESSION_PAYLOAD_VERSION);
    for i in 8 {
        out.push(((issued >> (56 - 8 * i)) & 255) as u8);
    }
    out.push(c.session_state.count as u8);
    for i in c.session_state.count {
        let key = c.session_state.entries[i].key[..];
        let value = c.session_state.entries[i].value[..];
        out.push(key.len as u8);
        out.append(key);
        out.push((value.len >> 8) as u8);
        out.push((value.len & 255) as u8);
        out.append(value);
    }
}

// Loads the entries of a payload into the store and returns the issue time, or -1 when the
// payload is malformed. The caller clears the store on -1.
fn session_read_payload(c: Ctx&, payload: const u8[:]) -> i64 {
    if payload.len < SESSION_HEADER_BYTES || payload.len > SESSION_MAX_PAYLOAD_BYTES { return -1; }
    if payload[0] != SESSION_PAYLOAD_VERSION { return -1; }
    // The issue time must fit a non-negative i64, so its top byte is below 128.
    if payload[1] >= 128 { return -1; }
    var issued: i64 = 0;
    for i in 8 {
        issued = issued * 256 + payload[1 + i];
    }
    let count = payload[9] as i64;
    if count > SESSION_MAX_ENTRIES { return -1; }
    c.session_state.count = 0;
    var pos: i64 = SESSION_HEADER_BYTES;
    for n in count {
        if pos >= payload.len { return -1; }
        let key_len = payload[pos] as i64;
        pos += 1;
        if key_len == 0 || key_len > SESSION_MAX_KEY_BYTES || pos + key_len + 2 > payload.len { return -1; }
        let key = payload[pos..pos + key_len];
        pos += key_len;
        let high: i64 = payload[pos];
        let value_len = high * 256 + payload[pos + 1];
        pos += 2;
        if value_len > SESSION_MAX_VALUE_BYTES || pos + value_len > payload.len { return -1; }
        let value = payload[pos..pos + value_len];
        pos += value_len;
        for k in c.session_state.count {
            if c.session_state.entries[k].key[..] == key { return -1; }
        }
        let slot = c.session_state.count;
        c.session_state.entries[slot].key = key;
        c.session_state.entries[slot].value = value;
        c.session_state.count += 1;
    }
    if pos != payload.len { return -1; }
    return issued;
}

// Appends the tag text for a payload text under the session label.
fn session_tag_text(out: u8[>..]&, secret: const u8[:], payload_text: const u8[:]) {
    var message: u8[>..] = [];
    message.append(SESSION_TAG_LABEL);
    message.append(payload_text);
    let tag = hmac_sha256(secret, message[..]);
    base64url_append(out, tag[..]);
}

// Appends the cookie value for the current store, issued at `issued`.
fn session_value(c: Ctx&, secret: const u8[:], issued: i64, out: u8[>..]&) {
    var payload: u8[>..] = [];
    session_write_payload(c, payload, issued);
    var text: u8[>..] = [];
    base64url_append(text, payload[..]);
    var tag: u8[>..] = [];
    session_tag_text(tag, secret, text[..]);
    out.append(text[..]);
    out.push('.');
    out.append(tag[..]);
}

// Authenticates a cookie value and loads its store into c.session_state. Returns false, with
// an empty store, when the value is absent, malformed, forged, issued in the future, or expired.
fn session_load(c: Ctx&, secret: const u8[:], raw: const u8[:], now: i64, max_age: i64) -> bool {
    c.session_state.count = 0;
    if raw.len == 0 || raw.len > MAX_COOKIE_LINE_BYTES || now <= 0 { return false; }
    let dot = find(raw, ".");
    if dot <= 0 || find(raw[dot + 1..], ".") >= 0 { return false; }
    let text = raw[..dot];
    let tag = raw[dot + 1..];
    var expected: u8[>..] = [];
    session_tag_text(expected, secret, text);
    if !constant_time_equal(expected[..], tag) { return false; }
    var payload: u8[>..] = [];
    if !base64url_decode(payload, text) { return false; }
    let issued = session_read_payload(c, payload[..]);
    if issued < 0 || issued > now + SESSION_CLOCK_SKEW_SECONDS || now - issued >= max_age {
        c.session_state.count = 0;
        return false;
    }
    return true;
}

// Writes the Set-Cookie line for the store: the new value while entries remain, or an expired
// cookie (Max-Age=0) when the store is empty. Lines over MAX_COOKIE_LINE_BYTES are not written;
// session_set bounds the payload so that cannot happen.
fn session_emit(c: Ctx&, config: SessionConfig) {
    let now = unix_seconds();
    if now <= 0 { return; }
    var line: u8[>..] = [];
    line.append(config.cookie[..]);
    line.push('=');
    if c.session_state.count > 0 {
        session_value(c, config.secret, now, line);
        format(line, "; Path=/; Max-Age=", config.max_age);
    } else {
        line.append("; Path=/; Max-Age=0");
    }
    line.append("; HttpOnly");
    if config.secure { line.append("; Secure"); }
    let same_site, _ = cookie_same_site(config.same_site[..]);
    format(line, "; SameSite=", same_site);
    if line.len > MAX_COOKIE_LINE_BYTES { return; }
    c.response.set_cookie_line = line[..];
}

// Session middleware: loads the signed cookie before Next, and after Next re-issues it when a
// handler changed the store. A missing, forged or expired cookie gives an empty store and is
// left for the client to drop.
fn session<Next>(c: Ctx&, config: SessionConfig) {
    assert(session_config_valid(config));
    c.session_state.active = true;
    c.session_state.dirty = false;
    let raw = cookie(c, config.cookie[..]);
    session_load(c, config.secret, raw, unix_seconds(), config.max_age);
    Next();
    if c.session_state.dirty { session_emit(c, config); }
}

// Value stored under key, or "" when the key is absent or no session middleware is installed.
fn session_get(c: Ctx&, key: const u8[:]) -> const u8[:] {
    for i in c.session_state.count {
        if c.session_state.entries[i].key[..] == key { return c.session_state.entries[i].value[..]; }
    }
    return "";
}

// Stores value under key, replacing an earlier value. Returns false, with the store unchanged,
// when no session middleware is installed, the key or value is out of bounds, the store is full,
// the clock is unavailable, or the payload would exceed SESSION_MAX_PAYLOAD_BYTES. Setting a key
// to the value it already has does not mark the store changed.
fn session_set(c: Ctx&, key: const u8[:], value: const u8[:]) -> bool {
    if !c.session_state.active || key.len == 0 || key.len > SESSION_MAX_KEY_BYTES { return false; }
    if value.len > SESSION_MAX_VALUE_BYTES || unix_seconds() <= 0 { return false; }
    var index: i64 = -1;
    for i in c.session_state.count {
        if c.session_state.entries[i].key[..] == key { index = i; }
    }
    var size = session_payload_size(c);
    if index >= 0 {
        if c.session_state.entries[index].value[..] == value { return true; }
        size += value.len - c.session_state.entries[index].value.len;
    } else {
        if c.session_state.count == SESSION_MAX_ENTRIES { return false; }
        size += SESSION_ENTRY_OVERHEAD_BYTES + key.len + value.len;
    }
    if size > SESSION_MAX_PAYLOAD_BYTES { return false; }
    if index >= 0 {
        c.session_state.entries[index].value = value;
    } else {
        let slot = c.session_state.count;
        c.session_state.entries[slot].key = key;
        c.session_state.entries[slot].value = value;
        c.session_state.count += 1;
    }
    c.session_state.dirty = true;
    return true;
}

// Removes every entry. The response then expires the session cookie.
fn session_clear(c: Ctx&) {
    if c.session_state.count == 0 { return; }
    c.session_state.count = 0;
    c.session_state.dirty = true;
}
