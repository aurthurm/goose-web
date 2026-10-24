// Rate limiting (fixed window, bounded table) and secure headers, through Ctx values.
import goose_web from "../..";
import std;

fn header_value(res: web::Response&, name: const u8[:]) -> const u8[:] {
    for i in res.headers.len {
        if res.headers[i].name == name { return res.headers[i].value; }
    }
    return "";
}

// One request from address, through rate_limit(limit, window_ms) around a text writer.
fn limited(address: const u8[:], limit: i64, window_ms: i64) -> web::Response {
    var out = web::response();
    var scratch = web::AppScratch { .. };
    var c = web::new_ctx(web::Request { method: "GET", target: "/", body: "", raw_headers: "Host: x\r\n", peer: address }, out, scratch);
    c.rate_limit(limit, window_ms) { c.text("ok"); };
    return copy(out);
}

fn secured(csp: const u8[:], hsts: const u8[:]) -> web::Response {
    var out = web::response();
    var scratch = web::AppScratch { .. };
    var c = web::new_ctx(web::Request { method: "GET", target: "/", body: "", raw_headers: "" }, out, scratch);
    c.secure_headers(csp, hsts) { c.text("secure"); };
    return copy(out);
}

// Routes with a wildcard and a host scope, described for OpenAPI.
fn described_routes(c: web::Ctx&) {
    web::openapi(c, web::OpenApiInfo { title: "Routing", version: "1.0.0" }) {
        c.routes() {
            c.host("api.example.com") { c.get("/files/*path") { c.text("scoped"); }; };
            c.get("/files/:id") { c.text("param"); };
        };
    };
}

fn main() {
    // The describe pass renders a wildcard as a {name} path parameter; host scopes are documented
    // like other routes.
    var spec_out = web::response();
    var spec_scratch = web::AppScratch { .. };
    var spec_request = web::new_ctx(web::Request { method: "GET", target: "/openapi.json", body: "", raw_headers: "" }, spec_out, spec_scratch);
    described_routes(spec_request);
    let spec = web::body_of(spec_out);
    assert(spec_out.status == 200);
    assert(find(spec, "\"/files/{path}\":{\"get\":") >= 0);
    assert(find(spec, "\"/files/{id}\":{\"get\":") >= 0);

    // Within the limit requests pass; the next one is refused with 429 and Retry-After.
    var first = limited("10.9.0.1", 2, 60000);
    var second = limited("10.9.0.1", 2, 60000);
    var third = limited("10.9.0.1", 2, 60000);
    assert(first.status == 200 && web::body_of(first) == "ok");
    assert(second.status == 200);
    assert(third.status == 429);
    assert(web::body_of(third) == "{\"error\":{\"code\":\"rate_limited\",\"message\":\"Too many requests\"}}\n");
    assert(header_value(third, "Retry-After").len > 0);
    assert(header_value(first, "Retry-After").len == 0);

    // Clients are separate, and so are policies for the same client.
    assert(limited("10.9.0.2", 2, 60000).status == 200);
    assert(limited("10.9.0.1", 5, 60000).status == 200);

    // The window arithmetic, with explicit clock values.
    let window: i64 = 1000;
    let admitted_first, unused_first = web::rate_take("window-key", 1, window, 100);
    assert(admitted_first);
    let refused, remaining = web::rate_take("window-key", 1, window, 500);
    assert(!refused && remaining == 600);
    let admitted_reset, unused_reset = web::rate_take("window-key", 1, window, 1100);
    assert(admitted_reset);
    let refused_again, retry = web::rate_take("window-key", 1, window, 1101);
    assert(!refused_again && retry == 999);

    // The table is bounded: far more distinct keys than entries keeps at most 1024 in use.
    var ticks: i64 = 2000;
    for i in 1100 {
        var key: u8[>..] = [];
        format(key, "bulk-", i);
        ticks += 1;
        web::rate_take(key[..], 1, window, ticks);
    }
    assert(web::rate_table_used() == 1024);

    // Secure headers: the fixed set, a configurable CSP, and HSTS only when configured.
    var plain = secured("default-src 'self'", "");
    assert(header_value(plain, "X-Content-Type-Options") == "nosniff");
    assert(header_value(plain, "X-Frame-Options") == "DENY");
    assert(header_value(plain, "Referrer-Policy") == "strict-origin-when-cross-origin");
    assert(header_value(plain, "Content-Security-Policy") == "default-src 'self'");
    assert(header_value(plain, "Strict-Transport-Security").len == 0);
    assert(web::body_of(plain) == "secure");
    var custom = secured("default-src 'none'; img-src 'self'", "max-age=31536000; includeSubDomains");
    assert(header_value(custom, "Content-Security-Policy") == "default-src 'none'; img-src 'self'");
    assert(header_value(custom, "Strict-Transport-Security") == "max-age=31536000; includeSubDomains");
    var no_csp = secured("", "");
    assert(header_value(no_csp, "Content-Security-Policy").len == 0);
    assert(header_value(no_csp, "X-Frame-Options") == "DENY");

    test_redirects_and_cors();
    print("App security tests passed: OpenAPI wildcards and host routes, rate_limit fixed window, Retry-After, per-client and per-policy buckets, bounded table, secure headers, local redirects, header injection refusals, CORS without credentials");
}

// One request through redirect_local to a target; the response is returned for inspection.
fn redirected(target: const u8[:]) -> web::Response {
    var out = web::response();
    var scratch = web::AppScratch { .. };
    var c = web::new_ctx(web::Request { method: "GET", target: "/login", body: "", raw_headers: "Host: x\r\n" }, out, scratch);
    c.redirect_local(target);
    return copy(out);
}

fn test_redirects_and_cors() {
    // Local absolute paths redirect with the given status; anything else is refused with 400.
    let home = redirected("/home?next=1");
    assert(home.status == 302 && header_value(home, "Location") == "/home?next=1");
    assert(redirected("/").status == 302);
    assert(redirected("/a%20b/c").status == 302);
    let refused = [
        "https://evil.example/", "http://evil.example/", "//evil.example/", "/\\evil.example",
        "javascript:alert(1)", "relative/path", "", "/ok\r\nSet-Cookie: x=1", "/tab\there",
    ];
    for i in refused.len {
        let answer = redirected(refused[i][..]);
        assert(answer.status == 400 && header_value(answer, "Location").len == 0);
        assert(find(web::body_of(answer), "\"code\":\"invalid_redirect\"") >= 0);
    }

    // A raw redirect with a CR/LF target is a 500, never a split header.
    var raw_out = web::response();
    var raw_scratch = web::AppScratch { .. };
    var raw_c = web::new_ctx(web::Request { method: "GET", target: "/x", body: "", raw_headers: "Host: x\r\n" }, raw_out, raw_scratch);
    web::redirect(raw_c, "/a\r\nSet-Cookie: x=1");
    assert(raw_c.response.status == 500 && header_value(raw_c.response, "Set-Cookie").len == 0);

    // set_cookie refuses CR/LF in the value and in the path, and writes nothing.
    var cookie_out = web::response();
    var cookie_scratch = web::AppScratch { .. };
    var cookie_c = web::new_ctx(web::Request { method: "GET", target: "/x", body: "", raw_headers: "Host: x\r\n" }, cookie_out, cookie_scratch);
    assert(!web::set_cookie(cookie_c, "sid", "a\r\nSet-Cookie: evil=1"));
    assert(!web::set_cookie(cookie_c, "sid", "abc", web::CookieOptions { path: "/\r\nX: y" }));
    assert(header_value(cookie_out, "Set-Cookie").len == 0);
    assert(web::set_cookie(cookie_c, "sid", "abc"));
    assert(header_value(cookie_out, "Set-Cookie") == "sid=abc; Path=/; HttpOnly; SameSite=Lax");

    // CORS: the wildcard answers with "*" and never with credentials, and an explicit origin adds Vary.
    var wild_out = web::response();
    var wild_scratch = web::AppScratch { .. };
    var wild = web::new_ctx(web::Request { method: "GET", target: "/api", body: "", raw_headers: "Host: x\r\nOrigin: https://app.example\r\n" }, wild_out, wild_scratch);
    web::cors(wild) { wild.text("cors"); };
    assert(header_value(wild_out, "Access-Control-Allow-Origin") == "*");
    assert(header_value(wild_out, "Vary").len == 0);
    assert(header_value(wild_out, "Access-Control-Allow-Credentials").len == 0);

    var pinned_out = web::response();
    var pinned_scratch = web::AppScratch { .. };
    var pinned = web::new_ctx(web::Request { method: "GET", target: "/api", body: "", raw_headers: "Host: x\r\n" }, pinned_out, pinned_scratch);
    web::cors(pinned, "https://app.example") { pinned.text("cors"); };
    assert(header_value(pinned_out, "Access-Control-Allow-Origin") == "https://app.example");
    assert(header_value(pinned_out, "Vary") == "Origin");
    assert(header_value(pinned_out, "Access-Control-Allow-Credentials").len == 0);

    // A preflight from any origin answers 204 with no credentials header.
    var pre_out = web::response();
    var pre_scratch = web::AppScratch { .. };
    var pre = web::new_ctx(web::Request { method: "OPTIONS", target: "/api", body: "", raw_headers: "Host: x\r\nAccess-Control-Request-Method: PUT\r\n" }, pre_out, pre_scratch);
    web::cors(pre) { pre.text("never"); };
    assert(pre.response.status == 204);
    assert(header_value(pre_out, "Access-Control-Allow-Credentials").len == 0);
    assert(header_value(pre_out, "Access-Control-Allow-Origin") == "*");
}
