// Application responses and middleware: c.json, c.json_list, body<T>, and the built-in
// middleware, through the same Ctx values the server builds.
import goose_web from "../..";
import std;

struct Item { id: i64, title: u8[..16], done: bool }
struct ItemIn { title: u8[..16], done: bool = false }
struct Patch { title: u8[..16] = "keep", done: bool = false }
struct Big { data: u8[..8192] }

// Nested-struct registration (docs/api.md): lists of Item encode through this pair.
fn web::json_put_value(out: u8[>..]&, v: Item&) -> bool { return web::json_put_fields(out, v); }

fn make_ctx(method: const u8[:], target: const u8[:], headers: const u8[:], body: const u8[:]) -> web::Ctx {
    return web::new_ctx(web::Request { method: method, target: target, body: body, raw_headers: headers });
}

fn header_value(res: web::Response&, name: const u8[:]) -> const u8[:] {
    for i in res.headers.len {
        if res.headers[i].name == name { return res.headers[i].value; }
    }
    return "";
}

// The error envelope carries the code as a JSON fragment, e.g. "\"code\":\"invalid_json\"".
fn expect_error(c: web::Ctx&, status: i32, fragment: const u8[:]) {
    assert(c.written);
    assert(c.response.status == status);
    assert(find(c.response.body[..], fragment) >= 0);
}

// --- body<T> ----------------------------------------------------------------------

fn test_body_success() {
    var c = make_ctx("POST", "/items", "Host: x\r\nContent-Type: application/json\r\n", "{\"title\":\"milk\"}");
    let input, ok = body<ItemIn>(c);
    assert(ok && input.title == "milk" && input.done == false);
    assert(!c.written);
    // Media type is case-insensitive and ignores parameters.
    var d = make_ctx("POST", "/items", "Host: x\r\nContent-Type: Application/JSON ; charset=utf-8\r\n", "{\"title\":\"a\"}");
    let again, ok2 = body<ItemIn>(d);
    assert(ok2 && again.title == "a");
}

fn test_body_patch_defaults_and_has() {
    var c = make_ctx("PATCH", "/items/1", "Host: x\r\nContent-Type: application/json\r\n", "{\"done\":true}");
    let patch, res = web::body_result<Patch>(c);
    assert(res.ok && patch.done && patch.title == "keep");
    assert(web::has<Patch>(res, "done"));
    assert(!web::has<Patch>(res, "title"));
    assert(!c.written);
    var empty = make_ctx("PATCH", "/items/1", "Host: x\r\nContent-Type: application/json\r\n", "{}");
    let none, res2 = web::body_result<Patch>(empty);
    assert(res2.ok && res2.present == 0 && none.title == "keep");
}

fn test_body_415() {
    var typed = make_ctx("POST", "/items", "Host: x\r\nContent-Type: text/plain\r\n", "{}");
    let a, ok = body<ItemIn>(typed);
    assert(!ok);
    expect_error(typed, web::HTTP_UNSUPPORTED_MEDIA_TYPE, "\"code\":\"unsupported_media_type\"");

    var missing = make_ctx("POST", "/items", "Host: x\r\n", "{\"title\":\"a\"}");
    let b, ok2 = body<ItemIn>(missing);
    assert(!ok2);
    expect_error(missing, web::HTTP_UNSUPPORTED_MEDIA_TYPE, "\"code\":\"unsupported_media_type\"");

    // A structured suffix is a different media type, not application/json.
    var suffix = make_ctx("POST", "/items", "Host: x\r\nContent-Type: application/jsonx\r\n", "{}");
    let d, ok3 = body<ItemIn>(suffix);
    assert(!ok3);
    expect_error(suffix, web::HTTP_UNSUPPORTED_MEDIA_TYPE, "\"code\":\"unsupported_media_type\"");
}

fn test_body_400() {
    var empty = make_ctx("POST", "/items", "Host: x\r\nContent-Type: application/json\r\n", "");
    let a, ok = body<ItemIn>(empty);
    assert(!ok);
    expect_error(empty, web::HTTP_BAD_REQUEST, "\"code\":\"invalid_json\"");
    assert(find(empty.response.body[..], "Request body is empty") >= 0);

    var syntax = make_ctx("POST", "/items", "Host: x\r\nContent-Type: application/json\r\n", "{\"title\":");
    let b, res = web::body_result<ItemIn>(syntax);
    assert(!res.ok && res.syntax);
    expect_error(syntax, web::HTTP_BAD_REQUEST, "\"code\":\"invalid_json\"");
    assert(find(syntax.response.body[..], "Malformed JSON: ") >= 0);

    var utf8 = make_ctx("POST", "/items", "Host: x\r\nContent-Type: application/json\r\n", "{\"title\":\"\xff\"}");
    let c, ok2 = body<ItemIn>(utf8);
    assert(!ok2);
    expect_error(utf8, web::HTTP_BAD_REQUEST, "\"code\":\"invalid_json\"");
}

fn test_body_422() {
    let long_title = "{\"title\":\"0123456789abcdefX\"}";
    var long = make_ctx("POST", "/items", "Host: x\r\nContent-Type: application/json\r\n", long_title);
    let a, ok = body<ItemIn>(long);
    assert(!ok);
    expect_error(long, web::HTTP_UNPROCESSABLE_CONTENT, "\"code\":\"invalid_payload\"");
    assert(find(long.response.body[..], "title: string too long") >= 0);

    var typed = make_ctx("PATCH", "/items", "Host: x\r\nContent-Type: application/json\r\n", "{\"done\":\"yes\"}");
    let b, ok2 = body<Patch>(typed);
    assert(!ok2);
    expect_error(typed, web::HTTP_UNPROCESSABLE_CONTENT, "\"code\":\"invalid_payload\"");
    assert(find(typed.response.body[..], "done: expected true or false") >= 0);

    var unknown = make_ctx("POST", "/items", "Host: x\r\nContent-Type: application/json\r\n", "{\"title\":\"a\",\"zzz\":1}");
    let c, ok3 = body<ItemIn>(unknown);
    assert(!ok3);
    assert(find(unknown.response.body[..], "zzz: unknown key") >= 0);

    var array = make_ctx("POST", "/items", "Host: x\r\nContent-Type: application/json\r\n", "[1]");
    let d, ok4 = body<ItemIn>(array);
    assert(!ok4);
    expect_error(array, web::HTTP_UNPROCESSABLE_CONTENT, "\"code\":\"invalid_payload\"");
    assert(find(array.response.body[..], "expected '{'") >= 0);
}

// --- c.json, c.json_list ----------------------------------------------------------

fn test_json_struct() {
    var c = make_ctx("GET", "/", "Host: x\r\n", "");
    c.json(Item { id: 7, title: "milk", done: false });
    assert(c.written && c.response.status == web::HTTP_OK);
    assert(c.response.content_type == "application/json");
    assert(c.response.body == "{\"id\":7,\"title\":\"milk\",\"done\":false}");
}

fn test_json_keeps_status() {
    var c = make_ctx("POST", "/items", "Host: x\r\n", "");
    c.status(web::HTTP_CREATED).json(Item { id: 1, title: "a", done: true });
    assert(c.response.status == web::HTTP_CREATED);
    assert(c.response.body == "{\"id\":1,\"title\":\"a\",\"done\":true}");
}

fn test_json_list() {
    var c = make_ctx("GET", "/items", "Host: x\r\n", "");
    var items: Item[..4] = [];
    items.push(Item { id: 1, title: "a", done: false });
    items.push(Item { id: 2, title: "b", done: true });
    c.json_list(items);
    assert(c.response.body == "[{\"id\":1,\"title\":\"a\",\"done\":false},{\"id\":2,\"title\":\"b\",\"done\":true}]");
    assert(c.response.content_type == "application/json");

    var none = make_ctx("GET", "/items", "Host: x\r\n", "");
    var empty: Item[..4] = [];
    json_list(none, empty[..]);
    assert(none.response.body == "[]");

    var nums = make_ctx("GET", "/n", "Host: x\r\n", "");
    let scalars: i64[3] = [1, 2, 3];
    json_list(nums, scalars[..]);
    assert(nums.response.body == "[1,2,3]");
}

fn test_json_too_large() {
    var c = make_ctx("GET", "/big", "Host: x\r\n", "");
    var big = Big { data: [] };
    for i in 8192 { big.data.push('a'); }
    c.json(big);
    expect_error(c, web::HTTP_INTERNAL_SERVER_ERROR, "\"code\":\"response_too_large\"");
}

fn test_json_encode_error() {
    var c = make_ctx("GET", "/bad", "Host: x\r\n", "");
    c.json(Item { id: 1, title: "\xff", done: true });
    expect_error(c, web::HTTP_INTERNAL_SERVER_ERROR, "\"code\":\"encode_error\"");
}

// --- middleware -------------------------------------------------------------------

fn test_request_id() {
    var a = make_ctx("GET", "/", "Host: x\r\n", "");
    var b = make_ctx("GET", "/", "Host: x\r\n", "");
    var reached = 0;
    request_id(a) { reached += 1; };
    request_id(b) { reached += 1; };
    assert(reached == 2);
    assert(a.request_id > 0 && b.request_id == a.request_id + 1);
    let expect = str(a.request_id);
    assert(header_value(a.response, "X-Request-ID") == expect[..]);
}

fn test_logger() {
    var c = make_ctx("POST", "/items?x=1", "Host: x\r\n", "");
    web::logger(c) { c.text("logged"); };
    assert(c.response.body == "logged");
    // Control bytes in the method and target are masked; nothing aborts.
    var odd = make_ctx("GE\nT", "/a\x01b", "Host: x\r\n", "");
    logger(odd) { };
    assert(odd.response.status == web::HTTP_OK);
}

fn test_cors_simple() {
    var c = make_ctx("GET", "/", "Host: x\r\n", "");
    web::cors(c) { c.text("ok"); };
    assert(c.response.body == "ok");
    assert(header_value(c.response, "Access-Control-Allow-Origin") == "*");
    assert(header_value(c.response, "Vary").len == 0);

    var d = make_ctx("GET", "/", "Host: x\r\n", "");
    cors(d, "https://a.example") { d.text("ok"); };
    assert(header_value(d.response, "Access-Control-Allow-Origin") == "https://a.example");
    assert(header_value(d.response, "Vary") == "Origin");
}

fn test_cors_preflight() {
    var c = make_ctx("OPTIONS", "/items", "Host: x\r\nAccess-Control-Request-Method: PUT\r\nAccess-Control-Request-Headers: X-Token, Content-Type\r\n", "");
    var reached = false;
    cors(c, "https://a.example") { reached = true; };
    assert(!reached);
    assert(c.response.status == web::HTTP_NO_CONTENT && c.response.body.len == 0);
    assert(header_value(c.response, "Access-Control-Allow-Origin") == "https://a.example");
    assert(header_value(c.response, "Vary") == "Origin");
    assert(header_value(c.response, "Access-Control-Allow-Methods") == "GET, POST, PUT, PATCH, DELETE, OPTIONS");
    assert(header_value(c.response, "Access-Control-Allow-Headers") == "X-Token, Content-Type");
    assert(header_value(c.response, "Access-Control-Max-Age") == "600");

    // Without requested headers the answer allows Content-Type.
    var bare = make_ctx("OPTIONS", "/items", "Host: x\r\nAccess-Control-Request-Method: POST\r\n", "");
    cors(bare) { };
    assert(header_value(bare.response, "Access-Control-Allow-Headers") == "Content-Type");

    // A valid requested-headers value is echoed; one over the header limit falls back.
    var echo = make_ctx("OPTIONS", "/items", "Host: x\r\nAccess-Control-Request-Method: POST\r\nAccess-Control-Request-Headers: abcdefghijklmnopqrst\r\n", "");
    cors(echo) { };
    assert(header_value(echo.response, "Access-Control-Allow-Headers") == "abcdefghijklmnopqrst");
    var huge_value: u8[>..] = [];
    for i in 300 { huge_value.push('h'); }
    let raw = str("Host: x\r\nAccess-Control-Request-Method: POST\r\nAccess-Control-Request-Headers: ", huge_value[..], "\r\n");
    var toolong = make_ctx("OPTIONS", "/items", raw[..], "");
    cors(toolong) { };
    assert(header_value(toolong.response, "Access-Control-Allow-Headers") == "Content-Type");
}

fn test_cors_options_without_request_method() {
    var plain = make_ctx("OPTIONS", "/items", "Host: x\r\n", "");
    var called = false;
    cors(plain) { called = true; };
    assert(called);
}

fn test_require_json() {
    var typed = make_ctx("POST", "/items", "Host: x\r\nContent-Type: text/plain\r\n", "x");
    var called = false;
    require_json(typed) { called = true; };
    assert(!called);
    expect_error(typed, web::HTTP_UNSUPPORTED_MEDIA_TYPE, "\"code\":\"unsupported_media_type\"");

    var good = make_ctx("POST", "/items", "Host: x\r\nContent-Type: Application/JSON; charset=utf-8\r\n", "{}");
    require_json(good) { called = true; };
    assert(called);
}

// Outer middleware runs before the inner one short-circuits, so its header survives.
fn test_nested_order() {
    var c = make_ctx("POST", "/items", "Host: x\r\nContent-Type: text/plain\r\n", "x");
    request_id(c) { logger(c) { cors(c, "https://a.example") { require_json(c) { c.text("never"); }; }; }; };
    assert(c.response.status == web::HTTP_UNSUPPORTED_MEDIA_TYPE);
    assert(header_value(c.response, "X-Request-ID").len > 0);
    assert(header_value(c.response, "Access-Control-Allow-Origin") == "https://a.example");
    assert(c.response.body != "never");

    // Preflight stops at cors, so the inner require_json never runs.
    var pre = make_ctx("OPTIONS", "/items", "Host: x\r\nAccess-Control-Request-Method: POST\r\n", "");
    var reached = false;
    logger(pre) { cors(pre) { require_json(pre) { reached = true; }; }; };
    assert(!reached && pre.response.status == web::HTTP_NO_CONTENT);
}

fn main() {
    test_body_success();
    test_body_patch_defaults_and_has();
    test_body_415();
    test_body_400();
    test_body_422();
    test_json_struct();
    test_json_keeps_status();
    test_json_list();
    test_json_too_large();
    test_json_encode_error();
    test_request_id();
    test_logger();
    test_cors_simple();
    test_cors_preflight();
    test_cors_options_without_request_method();
    test_require_json();
    test_nested_order();
    print("App middleware tests passed: body, json, json_list, request_id, logger, cors, require_json");
}
