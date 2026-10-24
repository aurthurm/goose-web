import src.constants.http;
import src.constants.limits;
import src.http.headers;
import src.http.request;
import src.http.response;
import src.sys.crypto;
import src.app.context;
import std;
namespace web;

// ETag and conditional GET (RFC 9110 section 8.8.3, 13.1.2). See docs/api.md#etag.

const HEADER_ETAG = "ETag";
const HEADER_IF_NONE_MATCH = "If-None-Match";
// Bytes of SHA-256 kept for the tag: 128 bits, quoted and base64url encoded (22 characters).
const ETAG_DIGEST_BYTES = 16;

// Index of the first response header named name, or -1.
fn etag_header_index(r: Response&, name: const u8[:]) -> i64 {
    for i in r.headers.len {
        if equal_header(r.headers[i].name, name) { return i; }
    }
    return -1;
}

// Strong entity tag for body: "<base64url of the first 16 bytes of SHA-256(body)>", quotes included.
fn etag_for(body: const u8[:], out: u8[>..]&) {
    let digest = sha256(body);
    out.push('"');
    base64url_append(out, digest[..ETAG_DIGEST_BYTES]);
    out.push('"');
}

// The entity-tag without a W/ prefix (the weak comparison of RFC 9110 8.8.3.2 ignores it).
fn etag_opaque(tag: const u8[:]) -> const u8[:] {
    if tag.len >= 2 && tag[0] == 'W' && tag[1] == '/' { return tag[2..]; }
    return tag;
}

// Whether an If-None-Match field value matches the entity-tag: "*", or any tag of the comma-separated list with
// the same opaque tag (weak comparison, so W/ is ignored on both sides). Surrounding whitespace is allowed.
fn if_none_match_hits(value: const u8[:], tag: const u8[:]) -> bool {
    let wanted = etag_opaque(tag);
    var start: i64 = 0;
    while start <= value.len {
        var stop = start;
        while stop < value.len && value[stop] != ',' { stop += 1; }
        let item = request_ows(value[start..stop]);
        if item == "*" { return true; }
        if item.len > 0 && etag_opaque(item) == wanted { return true; }
        start = stop + 1;
    }
    return false;
}

// Conditional GET. After the inner chain: a 200 GET or HEAD response gets an ETag, computed from SHA-256 of
// its body unless the handler set one (a body is required to compute it). When If-None-Match matches, the
// response becomes 304 Not Modified with no body and no Content-Type. ETag and Cache-Control are kept, as
// RFC 9110 section 15.4.5 asks. Other methods, statuses, SSE streams and empty computed bodies are left alone.
fn etag<Next>(c: Ctx&) {
    Next();
    let method = c.method();
    if (method != METHOD_GET && method != METHOD_HEAD) || c.response.status != HTTP_OK || c.response.sse { return; }
    let inm = c.header(HEADER_IF_NONE_MATCH);
    let own = etag_header_index(c.response, HEADER_ETAG);
    var hit = false;
    if own >= 0 {
        hit = inm.len > 0 && if_none_match_hits(inm, c.response.headers[own].value[..]);
    } else {
        if body_len(c.response) == 0 { return; }
        var computed: u8[>..] = [];
        etag_for(body_of(c.response), computed);
        assert(set_header(c.response, HEADER_ETAG, computed[..]));
        hit = inm.len > 0 && if_none_match_hits(inm, computed[..]);
    }
    if !hit { return; }
    c.response.status = HTTP_NOT_MODIFIED;
    c.response.content_type = "";
    drop_body(c.response);
}

// Sets Cache-Control (e.g. "public, max-age=60", "no-cache"). The value must be a valid header value.
fn cache_control(c: Ctx&, value: const u8[:]) -> Ctx& {
    return set(c, HEADER_CACHE_CONTROL, value);
}
