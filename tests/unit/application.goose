import goose_web from "../..";
import std;

fn before(request: web::Request, result: web::Response&) -> bool {
    web::append_body(result, "before;");
    return true;
}
fn handler(request: web::Request, result: web::Response&) { web::append_body(result, "handler;"); }
fn after(request: web::Request, result: web::Response&) { web::append_body(result, "after;"); }
fn reject(request: web::Request, result: web::Response&) -> bool {
    result.status = 503;
    web::append_body(result, "reject;");
    return false;
}
fn nested(request: web::Request, result: web::Response&) {
    web::pipeline(request, result, before, handler, after);
}
fn nested_reject(request: web::Request, result: web::Response&) {
    web::pipeline(request, result, reject, handler, after);
}

fn main() {
    let request = web::Request { method: "GET", target: "/", body: "", raw_headers: "" };
    var result = web::response();
    web::pipeline(request, result, before, handler, after);
    assert(web::body_of(result) == "before;handler;after;");
    result = web::response();
    web::pipeline(request, result, reject, handler, after);
    assert(result.status == 503 && web::body_of(result) == "reject;after;");
    result = web::response();
    web::pipeline(request, result, before, nested, after);
    assert(web::body_of(result) == "before;before;handler;after;after;");
    result = web::response();
    web::pipeline(request, result, before, nested_reject, after);
    assert(result.status == 503 && web::body_of(result) == "before;reject;after;after;");

    assert(web::set_header(result, "X-Request-Id", "request-7"));
    result.content_type = "text/plain";
    assert(web::set_body(result, "borrowed \"body\""));
    assert(web::application_error(result, 400, result.content_type, web::body_of(result)));
    assert(result.status == 400 && result.content_type == "application/json");
    assert(web::body_of(result) == "{\"error\":{\"code\":\"text/plain\",\"message\":\"borrowed \\\"body\\\"\"}}\n");
    assert(result.headers.len == 1 && result.headers[0].value == "request-7");
    assert(web::application_error(result, 503, "queue_full", "Try later"));
    assert(result.status == 503 && result.content_type == "application/json");
    assert(result.headers.len == 1 && result.headers[0].value == "request-7");
    assert(web::body_of(result) == "{\"error\":{\"code\":\"queue_full\",\"message\":\"Try later\"}}\n");
    assert(web::application_error(result, 400, "a\"b\\", "\x00\t\n\r\x1f"));
    assert(web::body_of(result) == "{\"error\":{\"code\":\"a\\\"b\\\\\",\"message\":\"\\u0000\\u0009\\u000a\\u000d\\u001f\"}}\n");
    assert(web::application_error(result, 599, "", "caf\xc3\xa9 \xf0\x9f\x90\xa5"));
    assert(find(web::body_of(result), "caf\xc3\xa9 \xf0\x9f\x90\xa5") >= 0);
    assert(web::application_error(result, 400, "", ""));

    // Error envelopes may use MAX_ERROR_BODY_BYTES beyond max_body, so a refused write can
    // still be replaced by its 500. A fresh response with a 64 KiB cap shows the boundary.
    var probe = web::response();
    assert(web::application_error(probe, 400, "", ""));
    let overhead = web::body_len(probe);
    var bounded = web::response();
    bounded.max_body = 65536;
    var exact: u8[>..] = [];
    for i in web::MAX_ERROR_BODY_BYTES + 1 { exact.push('x'); }
    assert(web::application_error(bounded, 413, "", exact[..web::MAX_ERROR_BODY_BYTES - overhead]));
    assert(web::body_len(bounded) == web::MAX_ERROR_BODY_BYTES && bounded.status == 413);
    assert(!web::application_error(bounded, 413, "", exact[..web::MAX_ERROR_BODY_BYTES + 1 - overhead]));
    let fallback = web::body_of(bounded);
    assert(bounded.status == 500 && find(fallback, "internal_error") >= 0);
    // Each control byte escapes to six characters, so a quarter-capacity run overflows the envelope.
    var controls: u8[>..] = [];
    for i in web::MAX_ERROR_BODY_BYTES / 4 { controls.push(0); }
    assert(!web::application_error(bounded, 400, "", controls));
    assert(web::body_of(bounded) == fallback && bounded.status == 500);
    let invalid_statuses: i32[4] = [0, 200, 399, 600];
    for status in invalid_statuses {
        assert(!web::application_error(bounded, status, "bad_status", "message"));
        assert(bounded.status == 500 && web::body_of(bounded) == fallback);
    }
    for invalid in ["\xff", "\xc0\x80", "\xe0\x80\x80", "\xed\xa0\x80", "\xf4\x90\x80\x80", "\xc3", "\xc3x"] {
        assert(!web::application_error(bounded, 400, "bad_utf8", invalid));
        assert(bounded.status == 500 && web::body_of(bounded) == fallback);
        assert(!web::application_error(bounded, 400, invalid, "message"));
    }
    assert(result.headers.len == 1 && result.headers[0].value == "request-7");
    print("Application tests passed: middleware ordering, rejection, nesting, escaped JSON, UTF-8, bounds");
}
