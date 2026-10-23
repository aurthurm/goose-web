import goose_web from "../..";
import std;

// Body counters prove which route bodies ran; the dispatch pass must run only one.
var static_hits: i64 = 0;
var param_hits: i64 = 0;

// The app is a generic function value bound by position: exchange(m, t, app).
fn exchange_with<App>(method: const u8[:], target: const u8[:], raw_headers: const u8[:]) -> web::Response {
    let request = web::Request { method: method, target: target, body: "", raw_headers: raw_headers };
    var c = web::new_ctx(request);
    App(c);
    return c.response;
}

fn exchange<App>(method: const u8[:], target: const u8[:]) -> web::Response {
    return exchange_with(method, target, "", App);
}

fn header_value(res: web::Response&, name: const u8[:]) -> const u8[:] {
    for i in res.headers.len {
        if res.headers[i].name == name { return res.headers[i].value; }
    }
    return "";
}

fn basic_app(c: web::Ctx&) {
    c.routes() {
        c.get("/static") { static_hits += 1; c.text("static"); };
        c.get("/:name") { param_hits += 1; c.text(c.param("name")); };
    };
}

fn group_app(c: web::Ctx&) {
    c.routes() {
        c.group("/api/") {
            c.get("/") { c.text("api root"); };
            c.get("/ping") { c.text("pong"); };
            c.group("/v1") {
                c.get("/users/:id") { c.text(c.param("id")); };
                c.get("/") { c.text("v1 root"); };
            };
        };
        c.get("/") { c.text("root"); };
    };
}

fn method_app(c: web::Ctx&) {
    c.routes() {
        c.get("/item") { c.text("get item"); };
        c.post("/item") { c.status(web::HTTP_CREATED).text("posted"); };
        c.head("/head") { c.text("explicit head"); };
        c.get("/head") { c.text("get head"); };
        c.get("/fallback") { c.text("fallback get"); };
    };
}

fn any_app(c: web::Ctx&) {
    c.routes() {
        c.get("/mixed") { c.text("get"); };
        c.any("/mixed") { c.text("any"); };
        c.any("/only") { c.text("only"); };
    };
}

fn params_app(c: web::Ctx&) {
    c.routes() {
        c.get("/users/:id/posts/:post") { c.text(str(c.param("id"), "/", c.param("post"))); };
        c.get("/p/:id") { c.text(str(c.param("id"), "|", c.param("nope"))); };
    };
}

fn int_app(c: web::Ctx&) {
    c.routes() {
        c.get("/n/:id") {
            let id, ok = c.param_int("id");
            guard ok else { return; }
            c.text(str(id));
        };
    };
}

fn query_app(c: web::Ctx&) {
    c.routes() {
        c.get("/q") {
            let n, ok = c.query_int("n", 7);
            guard ok else { return; }
            c.text(str(n));
        };
    };
}

fn chain_app(c: web::Ctx&) {
    c.routes() {
        c.get("/made") { c.status(web::HTTP_CREATED).set("X-Made", "yes").text("made"); };
        c.get("/set") { c.set("X-One", "a").set("x-one", "b"); c.text("set"); };
        c.get("/hdr") { c.text(c.header("x-demo")); };
        c.get("/req") { c.text(str(c.method(), " ", c.path(), " ", c.target())); };
    };
}

fn writers_app(c: web::Ctx&) {
    c.routes() {
        c.get("/html") { c.html("<p>hi</p>"); };
        c.get("/json") { c.json_raw("{\"a\":1}"); };
        c.get("/empty") { c.no_content(); };
        c.get("/go") { c.redirect("/elsewhere"); };
        c.get("/moved") { c.redirect("/new", web::HTTP_MOVED_PERMANENTLY); };
        c.get("/bad-go") { c.redirect("/a\r\nb"); };
        c.get("/fail") { c.fail(409, "conflict", "Already exists"); };
        c.get("/big") { var big: u8[>..] = []; for i in 8193 { big.push('x'); } c.text(big); };
        c.get("/edge") { var edge: u8[>..] = []; for i in 8192 { edge.push('y'); } c.text(edge); };
    };
}

// `return` inside a route body ends the enclosing function, which is the early-exit idiom.
var early_after: i64 = 0;
fn early_app(c: web::Ctx&) {
    c.routes() {
        c.get("/early") { c.text("early"); return; };
        c.get("/loop") {
            for i in 5 { if i == 2 { c.text("found"); return; } }
            c.text("missed");
        };
    };
    early_after += 1;
    c.text("fell through");
}

fn empty_app(c: web::Ctx&) {
    c.routes() {};
}

fn main() {
    // Static segments beat params; only the selected body runs.
    let s = exchange("GET", "/static", basic_app);
    assert(s.status == 200 && s.body == "static" && static_hits == 1 && param_hits == 0);
    let p = exchange("GET", "/other", basic_app);
    assert(p.status == 200 && p.body == "other" && static_hits == 1 && param_hits == 1);
    let wrong = exchange("POST", "/static", basic_app);
    assert(wrong.status == 405 && static_hits == 1 && param_hits == 1);

    // Groups compose, a trailing slash in the prefix is ignored, and "/" names the group.
    assert(exchange("GET", "/api", group_app).body == "api root");
    assert(exchange("GET", "/api/ping", group_app).body == "pong");
    assert(exchange("GET", "/api/v1", group_app).body == "v1 root");
    assert(exchange("GET", "/api/v1/users/9", group_app).body == "9");
    assert(exchange("GET", "/", group_app).body == "root");
    assert(exchange("GET", "/api/v1/users/9/", group_app).status == 404);
    let grouped_wrong = exchange("DELETE", "/api/ping", group_app);
    assert(grouped_wrong.status == 405 && header_value(grouped_wrong, "Allow") == "GET, HEAD");

    // 404 and the JSON envelope.
    let missing = exchange("GET", "/a/b/c", basic_app);
    assert(missing.status == 404 && missing.body == "{\"error\":{\"code\":\"not_found\",\"message\":\"Route not found\"}}\n");
    assert(exchange("GET", "/anything", empty_app).status == 404);

    // 405 with exact Allow in registration order; HEAD is added after GET.
    var item = exchange("DELETE", "/item", method_app);
    assert(item.status == 405 && header_value(item, "Allow") == "GET, HEAD, POST");
    assert(item.body == "{\"error\":{\"code\":\"method_not_allowed\",\"message\":\"Method not allowed for this route\"}}\n");
    var fallback_allow = exchange("POST", "/fallback", method_app);
    assert(header_value(fallback_allow, "Allow") == "GET, HEAD");
    assert(exchange("POST", "/item", method_app).status == 201);
    assert(exchange("POST", "/item", method_app).body == "posted");
    assert(exchange("GET", "/item", method_app).body == "get item");

    // HEAD falls back to GET unless HEAD is declared explicitly; explicit HEAD wins.
    let fallback = exchange("HEAD", "/fallback", method_app);
    assert(fallback.status == 200 && fallback.body == "fallback get");
    assert(exchange("HEAD", "/head", method_app).body == "explicit head");
    assert(exchange("GET", "/head", method_app).body == "get head");
    var head_allow = exchange("DELETE", "/head", method_app);
    assert(header_value(head_allow, "Allow") == "HEAD, GET");

    // any() serves every method; explicit methods on the same path win first.
    assert(exchange("GET", "/mixed", any_app).body == "get");
    assert(exchange("POST", "/mixed", any_app).body == "any");
    assert(exchange("PUT", "/mixed", any_app).body == "any");
    assert(exchange("HEAD", "/mixed", any_app).body == "get");
    assert(exchange("DELETE", "/only", any_app).body == "only");
    assert(exchange("GET", "/only", any_app).status == 200);

    // Several path params bind into the selected route only.
    assert(exchange("GET", "/users/5/posts/hello", params_app).body == "5/hello");
    assert(exchange("GET", "/p/7?x=1", params_app).body == "7|");

    // param_int: canonical non-negative decimal, else 422 invalid_param.
    let ok42 = exchange("GET", "/n/42", int_app);
    assert(ok42.status == 200 && ok42.body == "42");
    assert(exchange("GET", "/n/0", int_app).body == "0");
    assert(exchange("GET", "/n/9223372036854775807", int_app).body == "9223372036854775807");
    let bad_int = "{\"error\":{\"code\":\"invalid_param\",\"message\":\"Path parameter must be a canonical non-negative integer\"}}\n";
    for bad in ["007", "abc", "-1", "+1", "9223372036854775808", "1e3"] {
        let r = exchange("GET", str("/n/", bad), int_app);
        assert(r.status == 422 && r.body == bad_int);
    }

    // query_int: default when missing, 400 invalid_query otherwise.
    assert(exchange("GET", "/q", query_app).body == "7");
    assert(exchange("GET", "/q?n=5", query_app).body == "5");
    assert(exchange("GET", "/q?n=%35", query_app).body == "5");
    assert(exchange("GET", "/q?n=1&n=2", query_app).body == "1");
    assert(exchange("GET", "/q?other=1", query_app).body == "7");
    for bad_query in ["n=abc", "n=", "n=+5", "n=%zz", "n=99999999999999999999", "n=05"] {
        let r = exchange("GET", str("/q?", bad_query), query_app);
        assert(r.status == 400 && r.body.len > 0);
    }
    assert(exchange("GET", "/q?n=%zz", query_app).status == 400);

    // Status chaining, header replacement, and request accessors.
    let made = exchange("GET", "/made", chain_app);
    assert(made.status == 201 && made.body == "made" && header_value(made, "X-Made") == "yes");
    let set_result = exchange("GET", "/set", chain_app);
    assert(header_value(set_result, "X-One") == "b" && set_result.body == "set");
    assert(exchange_with("GET", "/hdr", "X-Demo: yes\r\nHost: x\r\n", chain_app).body == "yes");
    assert(exchange("GET", "/req?z=1", chain_app).body == "GET /req /req?z=1");

    // Writers: content type, body, 204, redirects, failures, and capacity.
    let html = exchange("GET", "/html", writers_app);
    assert(html.content_type == web::CONTENT_TYPE_HTML && html.body == "<p>hi</p>");
    let json = exchange("GET", "/json", writers_app);
    assert(json.content_type == web::CONTENT_TYPE_JSON && json.body == "{\"a\":1}");
    let empty = exchange("GET", "/empty", writers_app);
    assert(empty.status == 204 && empty.body == "");
    let go = exchange("GET", "/go", writers_app);
    assert(go.status == 302 && header_value(go, "Location") == "/elsewhere");
    let moved = exchange("GET", "/moved", writers_app);
    assert(moved.status == 301 && header_value(moved, "Location") == "/new");
    let bad_go = exchange("GET", "/bad-go", writers_app);
    assert(bad_go.status == 500 && bad_go.body == "{\"error\":{\"code\":\"invalid_redirect\",\"message\":\"Redirect location is invalid\"}}\n");
    let failed = exchange("GET", "/fail", writers_app);
    assert(failed.status == 409 && failed.body == "{\"error\":{\"code\":\"conflict\",\"message\":\"Already exists\"}}\n");
    let big = exchange("GET", "/big", writers_app);
    assert(big.status == 500 && big.body == "{\"error\":{\"code\":\"response_too_large\",\"message\":\"Response body exceeds capacity\"}}\n");
    assert(exchange("GET", "/edge", writers_app).body.len == 8192);

    // `return` in a route body ends the enclosing function; the fall-through text never runs.
    let early = exchange("GET", "/early", early_app);
    assert(early.body == "early" && early_after == 0);
    let looped = exchange("GET", "/loop", early_app);
    assert(looped.body == "found" && early_after == 0);
    let fell = exchange("GET", "/none", early_app);
    assert(fell.status == 404 && early_after == 1);

    // done() reflects whether a writer has run; a fresh Ctx is not done.
    var fresh = web::new_ctx(web::Request { method: "GET", target: "/", body: "", raw_headers: "" });
    assert(!done(fresh) && fresh.response.status == 200);
    text(fresh, "hello");
    assert(done(fresh) && fresh.response.body == "hello");

    print("App route tests passed: priority, groups, 404/405/Allow, HEAD, any, params, int/query parsing, writers, return");
}
