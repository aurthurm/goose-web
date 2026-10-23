import src.constants.http;
import src.constants.limits;
import src.constants.runtime;
import src.http.headers;
import src.http.errors;
import src.http.request;
import src.app.context;
import src.app.respond;
import src.sys.process;
import std;
namespace web;

const HEADER_RETRY_AFTER = "Retry-After";
const HEADER_X_CONTENT_TYPE_OPTIONS = "X-Content-Type-Options";
const HEADER_X_FRAME_OPTIONS = "X-Frame-Options";
const HEADER_REFERRER_POLICY = "Referrer-Policy";
const HEADER_CONTENT_SECURITY_POLICY = "Content-Security-Policy";
const HEADER_STRICT_TRANSPORT_SECURITY = "Strict-Transport-Security";
const REFERRER_POLICY_DEFAULT = "strict-origin-when-cross-origin";

// Middleware is `fn name<Next>(c: Ctx&, ...) { before; Next(); after; }`: the block
// after the call is Next, and not calling it short-circuits the request.

const HEADER_ACCESS_CONTROL_ALLOW_ORIGIN = "Access-Control-Allow-Origin";
const HEADER_ACCESS_CONTROL_ALLOW_METHODS = "Access-Control-Allow-Methods";
const HEADER_ACCESS_CONTROL_ALLOW_HEADERS = "Access-Control-Allow-Headers";
const HEADER_ACCESS_CONTROL_MAX_AGE = "Access-Control-Max-Age";
const HEADER_ACCESS_CONTROL_REQUEST_METHOD = "Access-Control-Request-Method";
const HEADER_ACCESS_CONTROL_REQUEST_HEADERS = "Access-Control-Request-Headers";
const HEADER_VARY = "Vary";
const CORS_ALLOW_METHODS = "GET, POST, PUT, PATCH, DELETE, OPTIONS";
const CORS_DEFAULT_ALLOW_HEADERS = "Content-Type";
const CORS_MAX_AGE_SECONDS = "600";

// Process-global, so ids stay unique across all connections on this reactor thread.
var request_counter: i64 = 0;

// Assigns the next id, stores it in c.request_id, and sets X-Request-ID before Next.
fn request_id<Next>(c: Ctx&) {
    request_counter += 1;
    c.request_id = request_counter;
    var text: u8[>..] = [];
    format(text, request_counter);
    c.set(HEADER_REQUEST_ID, text[..]);
    Next();
}

// Replaces control bytes so a crafted target cannot split the log line.
fn log_text(out: u8[>..]&, text: const u8[:]) {
    for ch in text {
        if ch < 32 || ch == 127 { out.push('?'); } else { out.push(ch); }
    }
}

// Prints one line after Next: METHOD path status bytes. Runs after the inner chain,
// including after a cors preflight short-circuit. Control bytes are masked, never fatal.
fn logger<Next>(c: Ctx&) {
    Next();
    var line: u8[>..] = [];
    log_text(line, c.method());
    line.push(' ');
    log_text(line, c.path());
    format(line, " ", c.response.status, " ", body_len(c.response));
    print(line);
}

// Adds Vary: Origin whenever the allowed origin is not the wildcard, so caches keyed on
// the request origin do not serve one origin's answer to another.
fn cors_origin_headers(c: Ctx&, origin: const u8[:]) {
    c.set(HEADER_ACCESS_CONTROL_ALLOW_ORIGIN, origin);
    if origin != "*" { c.set(HEADER_VARY, "Origin"); }
}

// Preflight: OPTIONS carrying Access-Control-Request-Method is answered here with 204
// and Next is not called, so routes and handlers never see preflight traffic.
fn cors<Next>(c: Ctx&, origin: const u8[:] = "*") {
    if c.method() == METHOD_OPTIONS && c.header(HEADER_ACCESS_CONTROL_REQUEST_METHOD).len > 0 {
        cors_origin_headers(c, origin);
        c.set(HEADER_ACCESS_CONTROL_ALLOW_METHODS, CORS_ALLOW_METHODS);
        // Echo the requested headers only when they are a valid header value.
        let requested = c.header(HEADER_ACCESS_CONTROL_REQUEST_HEADERS);
        let allow = if requested.len > 0 && valid_response_header(HEADER_ACCESS_CONTROL_ALLOW_HEADERS, requested) {
            requested
        } else {
            CORS_DEFAULT_ALLOW_HEADERS
        };
        c.set(HEADER_ACCESS_CONTROL_ALLOW_HEADERS, allow);
        c.set(HEADER_ACCESS_CONTROL_MAX_AGE, CORS_MAX_AGE_SECONDS);
        c.no_content();
        return;
    }
    cors_origin_headers(c, origin);
    Next();
}

// Rejects any request whose Content-Type media type is not application/json. The
// check applies to every request inside the block, so wrap body-carrying routes.
fn require_json<Next>(c: Ctx&) {
    if !is_json_media_type(c.header(HEADER_CONTENT_TYPE)) {
        c.fail(HTTP_UNSUPPORTED_MEDIA_TYPE, "unsupported_media_type", "Content-Type must be application/json");
        return;
    }
    Next();
}

// Security headers, set before Next so a handler can still replace one with c.set. An empty
// content_security_policy leaves CSP unset (a page that loads scripts from a CDN may need that).
// HSTS is sent only when hsts is nonempty, since it pins HTTPS for the host.
fn secure_headers<Next>(c: Ctx&, content_security_policy: const u8[:], hsts: const u8[:]) {
    c.set(HEADER_X_CONTENT_TYPE_OPTIONS, "nosniff");
    c.set(HEADER_X_FRAME_OPTIONS, "DENY");
    c.set(HEADER_REFERRER_POLICY, REFERRER_POLICY_DEFAULT);
    if content_security_policy.len > 0 { c.set(HEADER_CONTENT_SECURITY_POLICY, content_security_policy); }
    if hsts.len > 0 { c.set(HEADER_STRICT_TRANSPORT_SECURITY, hsts); }
    Next();
}

// Rate limiting is a fixed window per key. The table is process-wide and bounded: a new key
// takes a free entry, or else recycles the least recently seen one (that client starts a fresh
// window). An entry with an empty key is unused.
const RATE_TABLE_ENTRIES = 1024;
const RATE_KEY_BYTES = 160;
const NANOSECONDS_PER_SECOND = 1000000000;

struct RateEntry { key: u8[..RATE_KEY_BYTES], window_start: i64, count: i64, last_seen: i64 }
var rate_entries: RateEntry[RATE_TABLE_ENTRIES] = [default<RateEntry>(); RATE_TABLE_ENTRIES];

// Entries in use; test hook for the bound.
fn rate_table_used() -> i64 {
    var used: i64 = 0;
    for i in RATE_TABLE_ENTRIES { if rate_entries[i].key.len > 0 { used += 1; } }
    return used;
}

// Counts one request for key. Returns true while the window's count is within limit; otherwise
// false, with the nanoseconds until that window resets.
fn rate_take(key: const u8[:], limit: i64, window_ns: i64, now: i64) -> bool, i64 {
    var slot: i64 = -1;
    var free: i64 = -1;
    var oldest: i64 = 0;
    for i in RATE_TABLE_ENTRIES {
        if rate_entries[i].key.len == 0 {
            if free < 0 { free = i; }
        } else {
            if rate_entries[i].key[..] == key {
                slot = i;
                break;
            }
            if rate_entries[i].last_seen < rate_entries[oldest].last_seen { oldest = i; }
        }
    }
    if slot < 0 {
        slot = if free >= 0 { free } else { oldest };
        rate_entries[slot].key.clear();
        rate_entries[slot].key.append(key);
        rate_entries[slot].window_start = now;
        rate_entries[slot].count = 0;
    }
    if now - rate_entries[slot].window_start >= window_ns {
        rate_entries[slot].window_start = now;
        rate_entries[slot].count = 0;
    }
    rate_entries[slot].last_seen = now;
    rate_entries[slot].count += 1;
    if rate_entries[slot].count <= limit { return true, 0; }
    return false, rate_entries[slot].window_start + window_ns - now;
}

// Fixed-window limit per client address (Request.peer), separate for each (limit, window_ms)
// pair. A refused request gets 429 rate_limited with Retry-After in whole seconds. Requests
// with no known peer share one bucket.
fn rate_limit<Next>(c: Ctx&, limit: i64, window_ms: i64) {
    assert(limit > 0 && window_ms > 0 && window_ms <= MAX_TIMEOUT_MS);
    var key: u8[>..] = [];
    key.append(peer(c));
    key.push('|');
    format(key, limit, "/", window_ms);
    let allowed, retry_ns = rate_take(key[..], limit, window_ms * NANOSECONDS_PER_MILLISECOND, clock_ns());
    if !allowed {
        var seconds: u8[>..] = [];
        format(seconds, (retry_ns + NANOSECONDS_PER_SECOND - 1) / NANOSECONDS_PER_SECOND);
        c.set(HEADER_RETRY_AFTER, seconds[..]);
        c.fail(HTTP_TOO_MANY_REQUESTS, "rate_limited", "Too many requests");
        return;
    }
    Next();
}
