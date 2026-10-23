// Typed query binding, cookies, repeated Set-Cookie headers and the static file path rules.
// Static checks run on the pure functions; the file-system cases run from the repository root.
import goose_web from "../..";
import std;

struct AllInts { a: i8 = 0, b: i16 = 0, c: i32 = 0, d: i64 = 0, e: u8 = 0, f: u16 = 0, g: u32 = 0, h: u64 = 0 }
struct Flags { enabled: bool = false, ratio: f32 = 0.0, big: f64 = 0.0, name: u8[..8] = "" }
struct Filter { limit: i32 = 10, q: u8[..16] = "none", active: bool = false }

// Each context borrows this response; a test finishes with one context before creating the next.
var shared_response = web::response();

fn ctx_for(target: const u8[:], headers: const u8[:]) -> web::Ctx {
    shared_response = web::response();
    return web::new_ctx(web::Request { method: "GET", target: target, body: "", raw_headers: headers }, shared_response);
}

// The error envelope carries the message as a JSON fragment.
fn expect_status_body(c: web::Ctx&, status: i32, fragment: const u8[:]) {
    assert(c.written);
    assert(c.response.status == status);
    assert(find(web::body_of(c.response), fragment) >= 0);
}

// Returns the nth header value with this name, or "" when there are fewer.
fn nth_header(res: web::Response&, name: const u8[:], nth: i64) -> const u8[:] {
    var seen: i64 = 0;
    for i in res.headers.len {
        if res.headers[i].name == name {
            if seen == nth { return res.headers[i].value[..]; }
            seen += 1;
        }
    }
    return "";
}

fn header_count(res: web::Response&, name: const u8[:]) -> i64 {
    var count: i64 = 0;
    for i in res.headers.len {
        if res.headers[i].name == name { count += 1; }
    }
    return count;
}

fn test_query_ints() {
    var c = ctx_for("/x?a=-128&b=-32768&c=-2147483648&d=-9223372036854775808&e=255&f=65535&g=4294967295&h=18446744073709551615", "Host: x\r\n");
    let v, ok = query<AllInts>(c);
    assert(ok && !c.written);
    assert(v.a == -128 && v.b == -32768 && v.c == -2147483648);
    assert(v.d == -9223372036854775807 - 1);
    assert(v.e == 255 && v.f == 65535 && v.g == 4294967295);
    assert(v.h == 18446744073709551615);

    var max = ctx_for("/x?a=127&d=9223372036854775807&h=0&c=2147483647", "Host: x\r\n");
    let m, mok = query<AllInts>(max);
    assert(mok && m.a == 127 && m.d == 9223372036854775807 && m.c == 2147483647);
}

fn test_query_int_errors() {
    var texts: const u8[:][12] = [
        "/x?a=128", "/x?a=-129", "/x?e=-1", "/x?e=256", "/x?h=18446744073709551616",
        "/x?d=01", "/x?d=+1", "/x?d=", "/x?d=1.5", "/x?d=-0", "/x?d=-", "/x?d=9223372036854775808",
    ];
    var messages: const u8[:][12] = [
        "a: integer out of range", "a: integer out of range", "e: must not be negative", "e: integer out of range",
        "h: integer out of range", "d: expected an integer", "d: expected an integer", "d: expected an integer",
        "d: expected an integer", "d: expected an integer", "d: expected an integer", "d: integer out of range",
    ];
    for i in texts.len {
        var c = ctx_for(texts[i], "Host: x\r\n");
        let v, ok = query<AllInts>(c);
        assert(!ok && v.a == 0);
        expect_status_body(c, web::HTTP_BAD_REQUEST, "\"code\":\"invalid_query\"");
        assert(find(web::body_of(c.response), messages[i]) >= 0);
    }
}

fn test_query_flags() {
    var c = ctx_for("/x?enabled=true&ratio=1.5&big=-0.25&name=abc", "Host: x\r\n");
    let v, ok = query<Flags>(c);
    assert(ok && v.enabled && v.ratio == 1.5 && v.big == -0.25 && v.name == "abc");

    var one = ctx_for("/x?enabled=1", "Host: x\r\n");
    let one_v, one_ok = query<Flags>(one);
    assert(one_ok && one_v.enabled);
    var zero = ctx_for("/x?enabled=0", "Host: x\r\n");
    let zero_v, zero_ok = query<Flags>(zero);
    assert(zero_ok && !zero_v.enabled);

    var bad = ctx_for("/x?enabled=yes", "Host: x\r\n");
    let bad_v, bad_ok = query<Flags>(bad);
    assert(!bad_ok);
    expect_status_body(bad, web::HTTP_BAD_REQUEST, "enabled: expected true, false, 1 or 0");

    var nan = ctx_for("/x?ratio=abc", "Host: x\r\n");
    let nan_v, nan_ok = query<Flags>(nan);
    assert(!nan_ok);
    expect_status_body(nan, web::HTTP_BAD_REQUEST, "ratio: expected a number");
}

fn test_query_strings_and_defaults() {
    var c = ctx_for("/x?q=a%20b+c", "Host: x\r\n");
    let v, ok = query<Filter>(c);
    assert(ok && v.q == "a b c");
    assert(v.limit == 10 && !v.active);

    var empty = ctx_for("/x", "Host: x\r\n");
    let e, eok = query<Filter>(empty);
    assert(eok && e.limit == 10 && e.q == "none" && !e.active);

    var long = ctx_for("/x?q=0123456789abcdefg", "Host: x\r\n");
    let lv, lok = query<Filter>(long);
    assert(!lok);
    expect_status_body(long, web::HTTP_BAD_REQUEST, "q: string too long");

    var utf = ctx_for("/x?q=%FF", "Host: x\r\n");
    let uv, uok = query<Filter>(utf);
    assert(!uok);
    expect_status_body(utf, web::HTTP_BAD_REQUEST, "q: invalid UTF-8");

    var sparse = ctx_for("/x?limit=5&&active=true&", "Host: x\r\n");
    let s, sok = query<Filter>(sparse);
    assert(sok && s.limit == 5 && s.active);
}

fn test_query_strict_keys() {
    var unknown = ctx_for("/x?zzz=1", "Host: x\r\n");
    let u, uok = query<Filter>(unknown);
    assert(!uok);
    expect_status_body(unknown, web::HTTP_BAD_REQUEST, "zzz: unknown key");

    var dup = ctx_for("/x?limit=1&limit=2", "Host: x\r\n");
    let d, dok = query<Filter>(dup);
    assert(!dok);
    expect_status_body(dup, web::HTTP_BAD_REQUEST, "limit: duplicate query parameter");

    var decode = ctx_for("/x?limit=%zz", "Host: x\r\n");
    let dv, dvok = query<Filter>(decode);
    assert(!dvok);
    expect_status_body(decode, web::HTTP_BAD_REQUEST, "query string could not be decoded");

    var raw_key = ctx_for("/x?%FF=1", "Host: x\r\n");
    let rv, rok = query<Filter>(raw_key);
    assert(!rok);
    expect_status_body(raw_key, web::HTTP_BAD_REQUEST, "Query parameter name is not valid UTF-8");

    var present = ctx_for("/x?active=0&q=x", "Host: x\r\n");
    let pv, pres = query_result<Filter>(present);
    assert(pres.ok && web::has<Filter>(pres, "active") && web::has<Filter>(pres, "q"));
    assert(!web::has<Filter>(pres, "limit"));
}

fn test_cookie_read() {
    let raw = "Host: x\r\nCookie: a=1; sid=abc; theme=\"dark\"; =bad; x; spaced =  two  \r\n";
    var c = ctx_for("/", raw);
    assert(c.cookie("sid") == "abc");
    assert(c.cookie("theme") == "dark");
    assert(c.cookie("a") == "1");
    assert(c.cookie("x") == "");
    assert(c.cookie("missing") == "");
    assert(c.cookie("") == "");
    assert(c.cookie("spaced") == "two");

    var first = ctx_for("/", "Host: x\r\nCookie: k=1; k=2\r\n");
    assert(first.cookie("k") == "1");
    var equals = ctx_for("/", "Host: x\r\nCookie: k=b=c\r\n");
    assert(equals.cookie("k") == "b=c");
    var none = ctx_for("/", "Host: x\r\n");
    assert(none.cookie("k") == "");
}

fn test_set_cookie_emit() {
    var c = ctx_for("/", "Host: x\r\n");
    assert(c.set_cookie("sid", "abc"));
    assert(nth_header(c.response, "Set-Cookie", 0) == "sid=abc; Path=/; HttpOnly; SameSite=Lax");

    var d = ctx_for("/", "Host: x\r\n");
    assert(d.set_cookie("sid", "abc", web::CookieOptions { max_age: 60, secure: true, same_site: "Strict" }));
    assert(nth_header(d.response, "Set-Cookie", 0) == "sid=abc; Path=/; Max-Age=60; HttpOnly; Secure; SameSite=Strict");

    var e = ctx_for("/", "Host: x\r\n");
    assert(e.set_cookie("n", "", web::CookieOptions { path: "/app", max_age: 0, http_only: false, same_site: "" }));
    assert(nth_header(e.response, "Set-Cookie", 0) == "n=; Path=/app; Max-Age=0");

    var f = ctx_for("/", "Host: x\r\n");
    assert(f.set_cookie("t", "v", web::CookieOptions { secure: true, same_site: "none" }));
    assert(nth_header(f.response, "Set-Cookie", 0) == "t=v; Path=/; HttpOnly; Secure; SameSite=None");
}

fn test_set_cookie_validation() {
    var c = ctx_for("/", "Host: x\r\n");
    assert(!c.set_cookie("", "v"));
    assert(!c.set_cookie("bad name", "v"));
    assert(!c.set_cookie("a=b", "v"));
    assert(!c.set_cookie("n", "a b"));
    assert(!c.set_cookie("n", "a;b"));
    assert(!c.set_cookie("n", "\"q\""));
    assert(!c.set_cookie("n", "a,b"));
    assert(!c.set_cookie("n", "a\\b"));
    assert(!c.set_cookie("n", "v", web::CookieOptions { path: "rel" }));
    assert(!c.set_cookie("n", "v", web::CookieOptions { path: "/a;b" }));
    assert(!c.set_cookie("n", "v", web::CookieOptions { same_site: "Bogus" }));
    assert(!c.set_cookie("n", "v", web::CookieOptions { same_site: "None" }));
    assert(header_count(c.response, "Set-Cookie") == 0);
    assert(c.set_cookie("n", "v!#$%&'()*+-./:<=>?@[]^_`{|}~"));
}

fn test_set_cookie_repeated() {
    var c = ctx_for("/", "Host: x\r\n");
    assert(c.set_cookie("a", "1", web::CookieOptions { path: "/" }));
    assert(c.set_cookie("b", "2", web::CookieOptions { path: "/api", secure: true }));
    assert(header_count(c.response, "Set-Cookie") == 2);
    assert(nth_header(c.response, "Set-Cookie", 0) == "a=1; Path=/; HttpOnly; SameSite=Lax");
    assert(nth_header(c.response, "Set-Cookie", 1) == "b=2; Path=/api; HttpOnly; Secure; SameSite=Lax");

    // Serialization accepts repeated Set-Cookie and keeps both lines on the wire.
    var out: u8[>..] = [];
    web::serialize_response(out, c.response);
    assert(find(out[..], "Set-Cookie: a=1; Path=/; HttpOnly; SameSite=Lax\r\n") >= 0);
    assert(find(out[..], "Set-Cookie: b=2; Path=/api; HttpOnly; Secure; SameSite=Lax\r\n") >= 0);
    assert(find(out[..], "HTTP/1.1 200 OK") == 0);

    // Other repeated names are still refused by serialization.
    var dup = web::response();
    assert(web::append_header(dup, "X-Dup", "1"));
    dup.headers.push(web::Header { name: "x-dup", value: "2" });
    var refused: u8[>..] = [];
    web::serialize_response(refused, dup);
    assert(find(refused[..], "HTTP/1.1 500") == 0);
}

fn test_append_header() {
    var r = web::response();
    assert(web::append_header(r, "X-A", "1"));
    assert(web::append_header(r, "x-a", "2"));
    assert(header_count(r, "X-A") == 1);
    assert(nth_header(r, "X-A", 0) == "2");
    assert(!web::append_header(r, "Content-Length", "3"));
    assert(!web::append_header(r, "X-Bad", "a\r\nb"));
}

fn check_decoded(raw: const u8[:]) -> i32 {
    var decoded: u8[>..] = [];
    if !web::static_decode(raw, decoded) { return web::HTTP_BAD_REQUEST; }
    return web::static_segments(decoded[..]);
}

fn test_static_security_table() {
    assert(check_decoded("") == web::HTTP_OK);
    assert(check_decoded("a.txt") == web::HTTP_OK);
    assert(check_decoded("a/b.css") == web::HTTP_OK);
    assert(check_decoded("dir/") == web::HTTP_OK);
    assert(check_decoded("a%20b.txt") == web::HTTP_OK);
    assert(check_decoded("a.b/c") == web::HTTP_OK);

    assert(check_decoded("../x") == web::HTTP_BAD_REQUEST);
    assert(check_decoded("a/../b") == web::HTTP_BAD_REQUEST);
    assert(check_decoded("a/..") == web::HTTP_BAD_REQUEST);
    assert(check_decoded("./a") == web::HTTP_BAD_REQUEST);
    assert(check_decoded("%2e%2e/x") == web::HTTP_BAD_REQUEST);
    assert(check_decoded("..%2fx") == web::HTTP_BAD_REQUEST);
    assert(check_decoded("a%2Fb") == web::HTTP_BAD_REQUEST);
    assert(check_decoded("a%2fb") == web::HTTP_BAD_REQUEST);
    assert(check_decoded("a%5cb") == web::HTTP_BAD_REQUEST);
    assert(check_decoded("a%5Cb") == web::HTTP_BAD_REQUEST);
    assert(check_decoded("a\\b") == web::HTTP_BAD_REQUEST);
    assert(check_decoded("a%00b") == web::HTTP_BAD_REQUEST);
    assert(check_decoded("a%0ab") == web::HTTP_BAD_REQUEST);
    assert(check_decoded("a%7fb") == web::HTTP_BAD_REQUEST);
    assert(check_decoded("a%4") == web::HTTP_BAD_REQUEST);
    assert(check_decoded("a%zz") == web::HTTP_BAD_REQUEST);
    assert(check_decoded("/etc/passwd") == web::HTTP_BAD_REQUEST);
    assert(check_decoded("/") == web::HTTP_BAD_REQUEST);
    assert(check_decoded("a//b") == web::HTTP_BAD_REQUEST);
    assert(check_decoded("a//") == web::HTTP_BAD_REQUEST);
    assert(check_decoded(".") == web::HTTP_BAD_REQUEST);

    assert(check_decoded(".env") == web::HTTP_NOT_FOUND);
    assert(check_decoded("a/.git/config") == web::HTTP_NOT_FOUND);
    assert(check_decoded("%2ehidden") == web::HTTP_NOT_FOUND);

    var decoded: u8[>..] = [];
    assert(web::static_decode("a%20b.txt", decoded));
    assert(decoded[..] == "a b.txt");
}

fn test_static_content_type() {
    assert(web::static_content_type("index.html") == "text/html; charset=utf-8");
    assert(web::static_content_type("A.HTM") == "text/html; charset=utf-8");
    assert(web::static_content_type("site/style.css") == "text/css; charset=utf-8");
    assert(web::static_content_type("app.js") == "text/javascript; charset=utf-8");
    assert(web::static_content_type("data.json") == "application/json");
    assert(web::static_content_type("logo.svg") == "image/svg+xml");
    assert(web::static_content_type("p.png") == "image/png");
    assert(web::static_content_type("p.JPG") == "image/jpeg");
    assert(web::static_content_type("p.jpeg") == "image/jpeg");
    assert(web::static_content_type("a.gif") == "image/gif");
    assert(web::static_content_type("favicon.ico") == "image/x-icon");
    assert(web::static_content_type("notes.txt") == "text/plain; charset=utf-8");
    assert(web::static_content_type("m.wasm") == "application/wasm");
    assert(web::static_content_type("a.bin") == "application/octet-stream");
    assert(web::static_content_type("noext") == "application/octet-stream");
    assert(web::static_content_type("dir.d/file") == "application/octet-stream");
}

// File-system mapping, run from the repository root (tests/run.py sets the working directory).
fn test_static_resolve() {
    var full: u8[>..] = [];
    assert(web::static_resolve("", "tests/fixtures/static", full) == web::HTTP_OK);
    assert(full[..] == "tests/fixtures/static/index.html");

    var docs: u8[>..] = [];
    assert(web::static_resolve("docs", "tests/fixtures/static", docs) == web::HTTP_OK);
    assert(docs[..] == "tests/fixtures/static/docs/index.html");

    var docs_slash: u8[>..] = [];
    assert(web::static_resolve("docs/", "tests/fixtures/static", docs_slash) == web::HTTP_OK);
    assert(docs_slash[..] == "tests/fixtures/static/docs/index.html");

    var hello: u8[>..] = [];
    assert(web::static_resolve("hello.txt", "tests/fixtures/static", hello) == web::HTTP_OK);
    assert(hello[..] == "tests/fixtures/static/hello.txt");

    var missing: u8[>..] = [];
    assert(web::static_resolve("missing.txt", "tests/fixtures/static", missing) == web::HTTP_NOT_FOUND);
    var no_index: u8[>..] = [];
    assert(web::static_resolve("docs/absent/", "tests/fixtures/static", no_index) == web::HTTP_NOT_FOUND);

    var escape: u8[>..] = [];
    assert(web::static_resolve("../app.goose", "tests/fixtures/static", escape) == web::HTTP_BAD_REQUEST);
    var hidden: u8[>..] = [];
    assert(web::static_resolve(".hidden", "tests/fixtures/static", hidden) == web::HTTP_NOT_FOUND);
}

// query<T> uses the JSON names too: `limit` is read as "size", and `secret` is not a parameter.
struct Page { limit: i64 = 10, q: u8[..16] = "none", secret: bool = false }
struct Pair2 { a: bool, b: bool }
fn web::json_key(v: Page&, field: const u8[:]) -> const u8[:] {
    if field == "limit" { return "size"; }
    return field;
}
fn web::json_skip(v: Page&, field: const u8[:]) -> bool { return field == "secret"; }
fn web::json_key(v: Pair2&, field: const u8[:]) -> const u8[:] { return "same"; }

fn test_query_json_keys() {
    var c = ctx_for("/x?size=5&q=a", "Host: x\r\n");
    let v, ok = query<Page>(c);
    assert(ok && v.limit == 5 && v.q == "a");

    // The declared name is no longer a query parameter, and neither is a skipped field.
    var old = ctx_for("/x?limit=5", "Host: x\r\n");
    let ov, ook = query<Page>(old);
    assert(!ook);
    expect_status_body(old, web::HTTP_BAD_REQUEST, "limit: unknown key");
    var hidden = ctx_for("/x?secret=true", "Host: x\r\n");
    let hv, hok = query<Page>(hidden);
    assert(!hok);
    expect_status_body(hidden, web::HTTP_BAD_REQUEST, "secret: unknown key");

    // Errors and duplicates name the key as sent.
    var bad = ctx_for("/x?size=abc", "Host: x\r\n");
    let bv, bok = query<Page>(bad);
    assert(!bok);
    expect_status_body(bad, web::HTTP_BAD_REQUEST, "size: expected an integer");
    var dup = ctx_for("/x?size=1&size=2", "Host: x\r\n");
    let dv, dok = query<Page>(dup);
    assert(!dok);
    expect_status_body(dup, web::HTTP_BAD_REQUEST, "size: duplicate query parameter");

    // has<T> keeps the declared name: `size` set, `limit` present by its declared name.
    var present = ctx_for("/x?size=2", "Host: x\r\n");
    let pv, pres = query_result<Page>(present);
    assert(pres.ok && web::has<Page>(pres, "limit") && !web::has<Page>(pres, "size"));

    // Two fields with one JSON name: the query fails with the duplicate message.
    var clash = ctx_for("/x?same=true", "Host: x\r\n");
    let cv, cok = query<Pair2>(clash);
    assert(!cok);
    expect_status_body(clash, web::HTTP_BAD_REQUEST, "duplicate JSON key name");
}

// Form bodies: POST with a urlencoded body. The same pair rules as query<T>.
struct Signup { name: u8[..16] = "", age: i64 = 0, news: bool = false }

// The raw header bytes live in a global, because the context borrows them.
var form_headers: u8[>..] = [];

fn form_ctx(content_type: const u8[:], body: const u8[:]) -> web::Ctx {
    shared_response = web::response();
    form_headers.clear();
    form_headers.append("Host: x\r\nContent-Type: ");
    form_headers.append(content_type);
    form_headers.append("\r\n");
    return web::new_ctx(web::Request { method: "POST", target: "/signup", body: body, raw_headers: form_headers[..] }, shared_response);
}

fn test_form_binding() {
    var c = form_ctx("application/x-www-form-urlencoded", "name=Ada+L&age=36&news=1");
    let v, ok = form<Signup>(c);
    assert(ok && !c.written);
    assert(v.name == "Ada L" && v.age == 36 && v.news);

    var charset = form_ctx("Application/X-WWW-Form-Urlencoded; charset=UTF-8", "name=%41");
    let cv, cok = form<Signup>(charset);
    assert(cok && cv.name == "A");

    var empty = form_ctx("application/x-www-form-urlencoded", "");
    let ev, eok = form<Signup>(empty);
    assert(eok && ev.name.len == 0 && ev.age == 0 && !ev.news);

    var sparse = form_ctx("application/x-www-form-urlencoded", "age=5&&");
    let sv, sok = form<Signup>(sparse);
    assert(sok && sv.age == 5);
}

fn test_form_errors() {
    var json_type = form_ctx("application/json", "name=x");
    let jv, jok = form<Signup>(json_type);
    assert(!jok);
    expect_status_body(json_type, web::HTTP_UNSUPPORTED_MEDIA_TYPE, "\"code\":\"unsupported_media_type\"");

    var unknown = form_ctx("application/x-www-form-urlencoded", "zzz=1");
    let uv, uok = form<Signup>(unknown);
    assert(!uok);
    expect_status_body(unknown, web::HTTP_BAD_REQUEST, "\"code\":\"invalid_form\"");
    assert(find(web::body_of(unknown.response), "zzz: unknown key") >= 0);

    var bad_age = form_ctx("application/x-www-form-urlencoded", "age=old");
    let av, aok = form<Signup>(bad_age);
    assert(!aok);
    expect_status_body(bad_age, web::HTTP_BAD_REQUEST, "age: expected an integer");

    var decode = form_ctx("application/x-www-form-urlencoded", "name=%zz");
    let dv, dok = form<Signup>(decode);
    assert(!dok);
    expect_status_body(decode, web::HTTP_BAD_REQUEST, "query string could not be decoded");

    var long = form_ctx("application/x-www-form-urlencoded", "name=0123456789abcdefg");
    let lv, lok = form<Signup>(long);
    assert(!lok);
    expect_status_body(long, web::HTTP_BAD_REQUEST, "name: string too long");
}

fn main() {
    test_query_json_keys();
    test_form_binding();
    test_form_errors();
    test_query_ints();
    test_query_int_errors();
    test_query_flags();
    test_query_strings_and_defaults();
    test_query_strict_keys();
    test_cookie_read();
    test_set_cookie_emit();
    test_set_cookie_validation();
    test_set_cookie_repeated();
    test_append_header();
    test_static_security_table();
    test_static_content_type();
    test_static_resolve();
    print("App params tests passed: query<T> classes and errors, cookies, repeated Set-Cookie, static path security");
}
