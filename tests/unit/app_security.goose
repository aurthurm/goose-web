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

    print("App security tests passed: OpenAPI wildcards and host routes, rate_limit fixed window, Retry-After, per-client and per-policy buckets, bounded table, secure headers");
}
