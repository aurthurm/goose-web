import goose_web from "../..";
import std;

fn before(request: web::Request, result: web::Response&) -> bool {
    result.body.append("before;");
    return true;
}
fn handler(request: web::Request, result: web::Response&) { result.body.append("handler;"); }
fn after(request: web::Request, result: web::Response&) { result.body.append("after;"); }
fn reject(request: web::Request, result: web::Response&) -> bool {
    result.status = 503;
    result.body.append("reject;");
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
    assert(result.body == "before;handler;after;");
    result = web::response();
    web::pipeline(request, result, reject, handler, after);
    assert(result.status == 503 && result.body == "reject;after;");
    result = web::response();
    web::pipeline(request, result, before, nested, after);
    assert(result.body == "before;before;handler;after;after;");
    result = web::response();
    web::pipeline(request, result, before, nested_reject, after);
    assert(result.status == 503 && result.body == "before;reject;after;after;");

    assert(web::set_header(result, "X-Request-Id", "request-7"));
    result.content_type = "text/plain";
    result.body = "borrowed \"body\"";
    assert(web::application_error(result, 400, result.content_type, result.body));
    assert(result.status == 400 && result.content_type == "application/json");
    assert(result.body == "{\"error\":{\"code\":\"text/plain\",\"message\":\"borrowed \\\"body\\\"\"}}\n");
    assert(result.headers.len == 1 && result.headers[0].value == "request-7");
    assert(web::application_error(result, 503, "queue_full", "Try later"));
    assert(result.status == 503 && result.content_type == "application/json");
    assert(result.headers.len == 1 && result.headers[0].value == "request-7");
    assert(result.body == "{\"error\":{\"code\":\"queue_full\",\"message\":\"Try later\"}}\n");
    assert(web::application_error(result, 400, "a\"b\\", "\x00\t\n\r\x1f"));
    assert(result.body == "{\"error\":{\"code\":\"a\\\"b\\\\\",\"message\":\"\\u0000\\u0009\\u000a\\u000d\\u001f\"}}\n");
    assert(web::application_error(result, 599, "", "caf\xc3\xa9 \xf0\x9f\x90\xa5"));
    assert(find(result.body, "caf\xc3\xa9 \xf0\x9f\x90\xa5") >= 0);
    assert(web::application_error(result, 400, "", ""));
    let overhead = result.body.len;
    var exact: u8[8192] = ['x'; 8192];
    assert(web::application_error(result, 413, "", exact[..8192 - overhead]));
    assert(result.body.len == 8192 && result.status == 413);
    assert(!web::application_error(result, 413, "", exact[..8193 - overhead]));
    let fallback = result.body;
    assert(result.status == 500 && find(fallback, "internal_error") >= 0);
    var controls: u8[8192] = [0; 8192];
    assert(!web::application_error(result, 400, "", controls));
    assert(result.body == fallback && result.status == 500);
    let invalid_statuses: i32[4] = [0, 200, 399, 600];
    for status in invalid_statuses {
        assert(!web::application_error(result, status, "bad_status", "message"));
        assert(result.status == 500 && result.body == fallback);
    }
    for invalid in ["\xff", "\xc0\x80", "\xe0\x80\x80", "\xed\xa0\x80", "\xf4\x90\x80\x80", "\xc3", "\xc3x"] {
        assert(!web::application_error(result, 400, "bad_utf8", invalid));
        assert(result.status == 500 && result.body == fallback);
        assert(!web::application_error(result, 400, invalid, "message"));
    }
    assert(result.headers.len == 1 && result.headers[0].value == "request-7");
    print("Application tests passed: middleware ordering, rejection, nesting, escaped JSON, UTF-8, bounds");
}
