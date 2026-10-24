// ETag and conditional GET: the tag from SHA-256, If-None-Match matching (lists, weak tags, *), the 304 shape,
// and responses the middleware leaves alone.
import goose_web from "../..";
import std;

var shared_response = web::response();
var shared_scratch = web::AppScratch { .. };

// Tag of the body "hello": base64url of the first 16 bytes of SHA-256("hello"), quoted.
const HELLO_TAG = "\"LPJNul-wow4m6Dsqxbning\"";

fn ctx_for(method: const u8[:], headers: const u8[:]) -> web::Ctx {
    shared_response = web::response();
    return web::new_ctx(web::Request { method: method, target: "/r", body: "", raw_headers: headers }, shared_response, shared_scratch);
}

// Headers with If-None-Match set to value (the value is a view; the request keeps it while the test runs).
fn with_inm(value: const u8[:]) -> u8[..] {
    return str("Host: x\r\nIf-None-Match: ", value, "\r\n");
}

fn etag_value(res: web::Response&) -> const u8[:] {
    for i in res.headers.len {
        if res.headers[i].name == "ETag" { return res.headers[i].value[..]; }
    }
    return "";
}

fn has_header(res: web::Response&, name: const u8[:]) -> bool {
    for i in res.headers.len {
        if res.headers[i].name == name { return true; }
    }
    return false;
}

fn test_tag_is_sha256_prefix() {
    var c = ctx_for("GET", "Host: x\r\n");
    web::etag(c) { c.text("hello"); };
    assert(c.response.status == web::HTTP_OK);
    assert(etag_value(c.response) == HELLO_TAG);
    assert(web::body_of(c.response) == "hello");
    // The same body gives the same tag.
    var again = ctx_for("GET", "Host: x\r\n");
    web::etag(again) { again.text("hello"); };
    assert(etag_value(again.response) == HELLO_TAG);
}

fn test_match_200_to_304() {
    let raw = with_inm(HELLO_TAG);
    var c = ctx_for("GET", raw[..]);
    web::etag(c) { c.text("hello"); };
    assert(c.response.status == web::HTTP_NOT_MODIFIED);
    assert(web::body_len(c.response) == 0);
    assert(etag_value(c.response) == HELLO_TAG);
    // RFC 9110 15.4.5: no Content-Type on a 304, and the head serializes without one.
    assert(c.response.content_type.len == 0);
    var out: u8[>..] = [];
    web::serialize_response(out, c.response, false, true, false);
    assert(find(out[..], "HTTP/1.1 304 Not Modified\r\n") == 0);
    assert(find(out[..], "Content-Type") < 0 && find(out[..], "Content-Length") < 0);
    assert(find(out[..], "ETag: \"LPJNul-wow4m6Dsqxbning\"\r\n") > 0);
}

fn test_weak_list_and_star() {
    let weak = with_inm(str("W/", HELLO_TAG)[..]);
    var a = ctx_for("GET", weak[..]);
    web::etag(a) { a.text("hello"); };
    assert(a.response.status == web::HTTP_NOT_MODIFIED);

    let listed = with_inm(str("\"abc\" ,  ", HELLO_TAG, ",W/\"zzz\"")[..]);
    var b = ctx_for("GET", listed[..]);
    web::etag(b) { b.text("hello"); };
    assert(b.response.status == web::HTTP_NOT_MODIFIED);

    let star = with_inm("*");
    var d = ctx_for("GET", star[..]);
    web::etag(d) { d.text("hello"); };
    assert(d.response.status == web::HTTP_NOT_MODIFIED && web::body_len(d.response) == 0);
}

fn test_mismatch_stays_200() {
    let other = with_inm("\"other\"");
    var a = ctx_for("GET", other[..]);
    web::etag(a) { a.text("hello"); };
    assert(a.response.status == web::HTTP_OK && web::body_of(a.response) == "hello");
    assert(etag_value(a.response) == HELLO_TAG);

    // An unquoted tag is not an entity-tag, so it does not match.
    let bare = with_inm("LPJNul-wow4m6Dsqxbning");
    var b = ctx_for("GET", bare[..]);
    web::etag(b) { b.text("hello"); };
    assert(b.response.status == web::HTTP_OK);

    // A substring of a tag is not a match.
    let partial = with_inm("\"LPJNul\"");
    var c = ctx_for("GET", partial[..]);
    web::etag(c) { c.text("hello"); };
    assert(c.response.status == web::HTTP_OK);
}

fn test_head_matches() {
    let raw = with_inm(HELLO_TAG);
    var c = ctx_for("HEAD", raw[..]);
    web::etag(c) { c.text("hello"); };
    assert(c.response.status == web::HTTP_NOT_MODIFIED && web::body_len(c.response) == 0);
}

fn test_other_methods_untouched() {
    let raw = with_inm(HELLO_TAG);
    var c = ctx_for("POST", raw[..]);
    web::etag(c) { c.text("hello"); };
    assert(c.response.status == web::HTTP_OK && !has_header(c.response, "ETag"));
    assert(web::body_of(c.response) == "hello");
}

fn test_non_200_untouched() {
    let raw = with_inm("*");
    var created = ctx_for("GET", raw[..]);
    web::etag(created) { created.status(web::HTTP_CREATED).text("made"); };
    assert(created.response.status == web::HTTP_CREATED && !has_header(created.response, "ETag"));

    var missing = ctx_for("GET", raw[..]);
    web::etag(missing) { missing.status(web::HTTP_NOT_FOUND).text("nope"); };
    assert(missing.response.status == web::HTTP_NOT_FOUND && !has_header(missing.response, "ETag"));
    assert(web::body_of(missing.response) == "nope");
}

fn test_empty_body_untouched() {
    let raw = with_inm("*");
    var c = ctx_for("GET", raw[..]);
    web::etag(c) { c.text(""); };
    assert(c.response.status == web::HTTP_OK && !has_header(c.response, "ETag"));
}

fn test_handler_etag_is_kept() {
    // A tag the handler set is matched, not recomputed.
    var plain = ctx_for("GET", "Host: x\r\n");
    web::etag(plain) { plain.set("ETag", "\"v1\"").text("body"); };
    assert(plain.response.status == web::HTTP_OK && etag_value(plain.response) == "\"v1\"");

    let raw = with_inm("\"v1\"");
    var matched = ctx_for("GET", raw[..]);
    web::etag(matched) { matched.set("ETag", "\"v1\"").text("body"); };
    assert(matched.response.status == web::HTTP_NOT_MODIFIED && etag_value(matched.response) == "\"v1\"");

    // A weak tag from the handler still matches the strong form in If-None-Match.
    let strong = with_inm("\"v1\"");
    var weak = ctx_for("GET", strong[..]);
    web::etag(weak) { weak.set("ETag", "W/\"v1\"").text("body"); };
    assert(weak.response.status == web::HTTP_NOT_MODIFIED && etag_value(weak.response) == "W/\"v1\"");
}

fn test_cache_control_helper() {
    var c = ctx_for("GET", "Host: x\r\n");
    web::etag(c) { c.cache_control("public, max-age=60").text("hello"); };
    assert(c.response.status == web::HTTP_OK && etag_value(c.response) == HELLO_TAG);
    var seen = false;
    for i in c.response.headers.len {
        if c.response.headers[i].name == "Cache-Control" {
            assert(c.response.headers[i].value[..] == "public, max-age=60");
            seen = true;
        }
    }
    assert(seen);
}

fn main() {
    test_tag_is_sha256_prefix();
    test_match_200_to_304();
    test_weak_list_and_star();
    test_mismatch_stays_200();
    test_head_matches();
    test_other_methods_untouched();
    test_non_200_untouched();
    test_empty_body_untouched();
    test_handler_etag_is_kept();
    test_cache_control_helper();
    print("ETag tests passed: tag, 304 shape, weak, list, *, mismatch, methods, status, handler tags");
}
