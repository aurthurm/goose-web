import src.constants.limits;
import std;
namespace web;

// Per-request state for the session and CSRF middleware. Kept apart from session.goose and
// csrf.goose so Ctx can hold it without an import cycle.

// Session store capacities. The payload bound keeps a whole Set-Cookie line, name and
// attributes included, under MAX_COOKIE_LINE_BYTES (see session.goose for the layout).
const SESSION_MAX_ENTRIES = 16;
const SESSION_MAX_KEY_BYTES = 32;
const SESSION_MAX_VALUE_BYTES = 256;
const SESSION_MAX_PAYLOAD_BYTES = 2816;
const SESSION_MIN_SECRET_BYTES = 32;
// Accepted issue times this far ahead of the server clock are refused as tampering or skew.
const SESSION_CLOCK_SKEW_SECONDS = 60;

// Unpadded base64url of a 32-byte value, and a token made of two such texts joined by '.'.
const BASE64URL_32_BYTES = 43;
const CSRF_TOKEN_BYTES = 87;
const CSRF_MAX_TOKEN_BYTES = 96;

struct SessionEntry { key: u8[..32] = "", value: u8[..256] = "" }

// Entries 0..count-1 are live. dirty means the store changed and the cookie must be re-issued.
// id is the shared-store record of a server-side session (SessionConfig.store); max_payload is the
// largest payload the mode can hold: the cookie bound, or one shared-store value in store mode.
struct SessionState {
    active: bool = false,
    dirty: bool = false,
    count: i64 = 0,
    entries: SessionEntry[16],
    id: u8[..43] = "",
    max_payload: i64 = SESSION_MAX_PAYLOAD_BYTES,
}

// The subject that basic_auth or bearer_auth verified for this request ("" when none did).
// It is set only by a verifying middleware, so a handler can trust it when it is nonempty.
const AUTH_SUBJECT_MAX_BYTES = 64;
struct AuthState {
    subject: u8[..64] = "",
}

// The token for this request: the cookie value that matched, or a freshly minted one.
struct CsrfState {
    active: bool = false,
    token: u8[..96] = "",
}
