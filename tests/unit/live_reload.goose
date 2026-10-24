// Development live reload middleware: script injection into text/html responses (scripts/dev.py).
import goose_web from "../..";
import std;

// Each context borrows this response; a test finishes with one context before creating the next.
var shared_response = web::response();
var shared_scratch = web::AppScratch { .. };

fn make_ctx() -> web::Ctx {
    shared_response = web::response();
    return web::new_ctx(web::Request { method: "GET", target: "/", body: "", raw_headers: "Host: x\r\n" }, shared_response, shared_scratch);
}

const SCRIPT = "http://127.0.0.1:8081/live.js";
const TAG = "<script src=\"http://127.0.0.1:8081/live.js\"></script>";

fn test_injects_before_last_body_close() {
    var c = make_ctx();
    web::live_reload(c, SCRIPT) { c.html("<html><body><p>a</p></body></html>"); };
    assert(web::body_of(c.response) == str("<html><body><p>a</p>", TAG, "</body></html>")[..]);
    assert(c.response.content_type == web::CONTENT_TYPE_HTML);
    // The last </body> wins, so a body string that mentions the tag stays intact.
    var d = make_ctx();
    web::live_reload(d, SCRIPT) { d.html("</body>x</body>"); };
    assert(web::body_of(d.response) == str("</body>x", TAG, "</body>")[..]);
}

fn test_appends_without_body_close() {
    var c = make_ctx();
    web::live_reload(c, SCRIPT) { c.html("<p>fragment</p>"); };
    assert(web::body_of(c.response) == str("<p>fragment</p>", TAG)[..]);
}

fn test_only_html() {
    var c = make_ctx();
    web::live_reload(c, SCRIPT) { c.text("<body>plain</body>"); };
    assert(web::body_of(c.response) == "<body>plain</body>");
    var j = make_ctx();
    web::live_reload(j, SCRIPT) { j.json_raw("{\"a\":\"</body>\"}"); };
    assert(web::body_of(j.response) == "{\"a\":\"</body>\"}");
}

fn test_unsafe_url_is_ignored() {
    var c = make_ctx();
    web::live_reload(c, "http://x/\"onload=alert(1)") { c.html("<body></body>"); };
    assert(web::body_of(c.response) == "<body></body>");
    assert(!web::live_reload_url_valid("a b"));
    assert(!web::live_reload_url_valid(""));
    assert(web::live_reload_url_valid("http://127.0.0.1:8081/live.js"));
}

fn test_max_body_keeps_response() {
    var c = make_ctx();
    // The 22-byte page fits in 30 bytes, but the script tag does not fit beside it.
    c.response.max_body = 30;
    web::live_reload(c, SCRIPT) { c.html("<body>0123456789</body>"); };
    assert(web::body_of(c.response) == "<body>0123456789</body>");
}

fn test_disabled_without_env() {
    // GOOSE_WEB_LIVE_RELOAD is unset when the suite runs, so the middleware only calls Next.
    var c = make_ctx();
    web::live_reload(c) { c.html("<body>x</body>"); };
    assert(web::body_of(c.response) == "<body>x</body>");
    assert(web::live_reload_env().len == 0);
}

fn test_sse_untouched() {
    var c = make_ctx();
    web::live_reload(c, SCRIPT) { c.sse(1); };
    assert(c.response.sse);
    assert(web::body_of(c.response).len == 0);
}

fn main() {
    test_injects_before_last_body_close();
    test_appends_without_body_close();
    test_only_html();
    test_unsafe_url_is_ignored();
    test_max_body_keeps_response();
    test_disabled_without_env();
    test_sse_untouched();
    print("Live reload tests passed: injection before </body>, append, text/html only, safe URLs, max_body, disabled");
}
