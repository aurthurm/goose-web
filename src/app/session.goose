import src.constants.http;
import src.constants.limits;
import src.constants.runtime;
import src.http.headers;
import src.app.context;
import src.app.cookies;
import src.app.session_state;
import src.sys.crypto;
import src.sys.process;
import src.sys.shared;
import src.app.shared;
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

// store = false (the default) keeps the whole session in the cookie. store = true keeps it in the shared
// store (docs/api.md#sessions): the cookie carries a random id and a tag, and the data lives in the store under
// that id for max_age seconds. Store mode needs the shared store (ServerConfig.shared_store_bytes > 0).
struct SessionConfig {
    secret: const u8[:],
    cookie: u8[..32] = "gw_session",
    max_age: i64 = 86400,
    secure: bool = false,
    same_site: u8[..8] = "Lax",
    store: bool = false,
}

const SESSION_PAYLOAD_VERSION = 1;
// Version, issue time and entry count.
const SESSION_HEADER_BYTES = 10;
// Key length, value length and the entry count are fixed-width fields of each entry.
const SESSION_ENTRY_OVERHEAD_BYTES = 3;
const SESSION_TAG_LABEL = "gw-session|";
// Store mode: the record id is 32 random bytes in base64url (43 characters); its tag is keyed separately.
const SESSION_ID_TAG_LABEL = "gw-session-id|";
const SESSION_RECORD_PREFIX = "sess:";

// Whether a config can be honoured. The middleware asserts this: a short secret or an
// impossible attribute is a defect in the application, not a client error.
fn session_config_valid(config: SessionConfig) -> bool {
    if config.secret.len < SESSION_MIN_SECRET_BYTES { return false; }
    if config.cookie.len == 0 || !token(config.cookie[..]) { return false; }
    if config.max_age <= 0 { return false; }
    // A stored record expires with max_age, and the store's longest time-to-live is SHARED_TTL_MAX_MS.
    if config.store && config.max_age > SHARED_TTL_MAX_MS / 1000 { return false; }
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

// Store mode: authenticates "id.tag", then loads the record the id names. Returns false, with an empty
// store, when the cookie is absent, malformed, forged, the record is gone or expired, or the record is malformed.
fn session_load_stored(c: Ctx&, secret: const u8[:], raw: const u8[:], now: i64, max_age: i64) -> bool {
    c.session_state.count = 0;
    c.session_state.id.clear();
    if raw.len == 0 || raw.len > MAX_COOKIE_LINE_BYTES || now <= 0 { return false; }
    let dot = find(raw, ".");
    if dot != BASE64URL_32_BYTES || find(raw[dot + 1..], ".") >= 0 { return false; }
    let id = raw[..dot];
    var expected: u8[>..] = [];
    session_id_tag(expected, secret, id);
    if !constant_time_equal(expected[..], raw[dot + 1..]) { return false; }
    var key: u8[>..] = [];
    session_record_key(key, id);
    var payload: u8[>..] = [];
    if !shared_get(key[..], payload) { return false; }
    let issued = session_read_payload(c, payload[..]);
    if issued < 0 || issued > now + SESSION_CLOCK_SKEW_SECONDS || now - issued >= max_age {
        c.session_state.count = 0;
        return false;
    }
    c.session_state.id = id;
    return true;
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

// Store mode: the record key for an id, "sess:" followed by the id text.
fn session_record_key(out: u8[>..]&, id: const u8[:]) {
    out.clear();
    out.append(SESSION_RECORD_PREFIX);
    out.append(id);
}

// Appends the tag of a store-mode id: HMAC-SHA256 of the id under the secret, with its own label.
fn session_id_tag(out: u8[>..]&, secret: const u8[:], id: const u8[:]) {
    var message: u8[>..] = [];
    message.append(SESSION_ID_TAG_LABEL);
    message.append(id);
    let tag = hmac_sha256(secret, message[..]);
    base64url_append(out, tag[..]);
}

// Store mode: writes the record for the current entries under a fresh or existing id, and appends the
// cookie value "id.tag". With no entries the record is deleted and the cookie expires. Returns false, with
// the record unchanged, when the write fails or no entropy is available, so the response keeps the old cookie.
fn session_store_write(c: Ctx&, config: SessionConfig, now: i64, line: u8[>..]&) -> bool {
    if c.session_state.count == 0 {
        if c.session_state.id.len > 0 {
            var key: u8[>..] = [];
            session_record_key(key, c.session_state.id[..]);
            shared_delete(key[..]);
            c.session_state.id.clear();
        }
        line.append("; Path=/; Max-Age=0");
        return true;
    }
    if c.session_state.id.len == 0 {
        var raw_id: u8[32] = [0; 32];
        if !random_bytes(raw_id[..]) { return false; }
        var id_text: u8[>..] = [];
        base64url_append(id_text, raw_id[..]);
        c.session_state.id = id_text[..];
    }
    var payload: u8[>..] = [];
    session_write_payload(c, payload, now);
    var key: u8[>..] = [];
    session_record_key(key, c.session_state.id[..]);
    if !shared_set(key[..], payload[..], config.max_age * 1000) { return false; }
    let id = c.session_state.id[..];
    line.append(id);
    line.push('.');
    session_id_tag(line, config.secret, id);
    format(line, "; Path=/; Max-Age=", config.max_age);
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
    if config.store {
        if !session_store_write(c, config, now, line) { return; }
    } else if c.session_state.count > 0 {
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
    assert(!config.store || shared_enabled());
    c.session_state.active = true;
    c.session_state.dirty = false;
    c.session_state.max_payload = if config.store { SHARED_VALUE_MAX_BYTES } else { SESSION_MAX_PAYLOAD_BYTES };
    let raw = cookie(c, config.cookie[..]);
    if config.store {
        session_load_stored(c, config.secret, raw, unix_seconds(), config.max_age);
    } else {
        session_load(c, config.secret, raw, unix_seconds(), config.max_age);
    }
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
// the clock is unavailable, or the payload would exceed the mode's bound (SESSION_MAX_PAYLOAD_BYTES in
// cookie mode, one shared-store value in store mode). Setting a key
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
    if size > c.session_state.max_payload { return false; }
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
