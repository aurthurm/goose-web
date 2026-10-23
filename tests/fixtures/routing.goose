import goose_web from "../..";
import std;
import os;

// Wildcards, host scopes, typed path parameters, the peer address, rate limiting and secure
// headers, served over real sockets. tests/integration/routing.py drives it.

fn app(c: web::Ctx&) {
    secure_headers(c) {
        c.routes() {
            c.get("/peer") { c.text(c.peer()); };
            c.get("/limited") { c.rate_limit(3, 60000) { c.text("limited ok"); }; };
            c.get("/files/*path") { c.text(c.param("path")); };
            c.get("/u/:id") {
                let id, ok = c.param_uuid("id");
                guard ok else { return; }
                c.text(id[..]);
            };
            c.get("/n/:id") {
                let id, ok = c.param_u64("id");
                guard ok else { return; }
                c.text(str(id));
            };
            c.get("/s/:slug") {
                let slug, ok = c.param_slug("slug");
                guard ok else { return; }
                c.text(slug[..]);
            };
            c.host("api.localhost") { c.get("/whoami") { c.text("api"); }; };
            c.host("*.localhost") { c.get("/whoami") { c.text("wild"); }; };
            c.get("/whoami") { c.text("plain"); };
        };
    }
}

fn main() {
    let argv = args();
    var port: i32 = web::DEFAULT_PORT;
    if argv.len > 1 {
        let value, ok = parse_int(argv[1]);
        if !ok || value < web::MIN_PORT || value > web::MAX_PORT { abort("invalid port"); }
        port = value as i32;
    }
    var config = web::server_config();
    config.port = port;
    config.max_requests = 0;
    print("Goose Web routing fixture listening on http://127.0.0.1:", port);
    let started = web::run(config) { c => app(c) };
    if !started { abort("server failed"); }
}
