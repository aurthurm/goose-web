import goose_web from "../..";
import std;

// Small DSL app served through web::run; tests/integration/app.py drives it over sockets.
fn app(c: web::Ctx&) {
    c.routes() {
        c.get("/health") { c.json_raw("{\"status\":\"ok\"}\n"); };
        c.group("/users") {
            c.get("/new") { c.text("new user form"); };
            c.get("/:id") {
                let id, ok = c.param_int("id");
                guard ok else { return; }
                c.text(str("user ", id));
            };
            c.post("/") { c.status(web::HTTP_CREATED).text("created"); };
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
    print("Goose Web app listening on http://127.0.0.1:", port);
    let started = web::run(config) { c => app(c) };
    if !started { abort("server failed"); }
}
