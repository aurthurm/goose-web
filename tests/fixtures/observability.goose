import goose_web from "../..";
import std;
import os;

// Observability fixture: JSON request logs on stdout, a trusted-proxy allow-list, ETag, load shedding and a
// per-route body cap. tests/integration/observability.py drives it over sockets. Run from the repository root:
//   observability <port> [workers]
// workers: run two worker processes, so the log lines carry a pid.

const TRUSTED_PROXIES = "127.0.0.1/32, 10.0.0.0/8";

fn app(c: web::Ctx&) {
    json_logger(c, false) {
        trust_proxies(c, web::trusted_proxies(TRUSTED_PROXIES)) {
            etag(c) {
                c.routes() {
                    c.get("/hello") { c.text("hello"); };
                    c.get("/users/:id") { c.text(str("user ", c.param("id"))); };
                    c.get("/ip") { c.text(client_ip(c)); };
                    c.get("/pressure") { c.json(server_pressure(c)); };
                    c.get("/limited") {
                        shed_load(c, web::LoadPolicy { max_active_connections_pct: 1, retry_after_s: 3 }) {
                            c.text("served");
                        };
                    };
                    c.post("/small") {
                        body_limit(c, 8) {
                            c.text(str("got ", c.request.body.len));
                        };
                    };
                };
            };
        };
    };
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
    if argv.len > 2 && argv[2] == "workers" { config.workers = 2; }
    let started = web::run(config) { c => app(c) };
    if !started { abort("server failed"); }
}
