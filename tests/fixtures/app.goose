import goose_web from "../..";
import std;
import os;

// Small DSL app served through web::run; tests/integration/app.py drives it over sockets.
struct Item { id: i64, title: u8[..16], done: bool }
struct ItemIn { title: u8[..16], done: bool = false }

// Nested-struct registration: lists of Item encode through this pair.
fn web::json_put_value(out: u8[>..]&, v: Item&) -> bool { return web::json_put_fields(out, v); }

// Typed query binding: every supported field class, with defaults for missing keys.
struct SearchQuery { limit: i32 = 10, q: u8[..32] = "", active: bool = false, score: f64 = 0.0 }

var items: Item[..8] = [];
var next_item_id: i64 = 1;

fn app(c: web::Ctx&) {
    request_id(c) { logger(c) { cors(c) {
        // Static files under /static, served before the routes below; tests/integration/app.py
        // runs this program from the repository root so the relative directory resolves.
        c.static_files("/static", "tests/fixtures/static") {
        c.routes() {
            c.get("/health") { c.json_raw("{\"status\":\"ok\"}\n"); };
            c.get("/search") {
                let query_args, ok = query<SearchQuery>(c);
                guard ok else { return; }
                c.json(query_args);
            };
            c.group("/cookies") {
                c.get("/set") {
                    let session_ok = c.set_cookie("session", "abc123", web::CookieOptions { max_age: 3600, secure: true, same_site: "Strict" });
                    let theme_ok = c.set_cookie("theme", "dark", web::CookieOptions { path: "/app", http_only: false });
                    guard session_ok && theme_ok else { c.fail(web::HTTP_INTERNAL_SERVER_ERROR, "cookie_rejected", "Cookie rejected"); return; }
                    c.text("cookies set");
                };
                c.get("/echo") { c.text(str("session=", c.cookie("session"), ";theme=", c.cookie("theme"))); };
            };
            c.group("/users") {
                c.get("/new") { c.text("new user form"); };
                c.get("/:id") {
                    let id, ok = c.param_int("id");
                    guard ok else { return; }
                    c.text(str("user ", id));
                };
                c.post("/") { c.status(web::HTTP_CREATED).text("created"); };
            };
            c.group("/api") {
                c.get("/items") { c.json_list(items[..]); };
                c.post("/items") {
                    let input, ok = body<ItemIn>(c);
                    guard ok else { return; }
                    if items.len == items.cap { c.fail(web::HTTP_CONFLICT, "items_full", "Item store is full"); return; }
                    items.push(Item { id: next_item_id, title: input.title, done: input.done });
                    next_item_id += 1;
                    c.status(web::HTTP_CREATED).json(items[items.len - 1]);
                };
            };
        };
        };
    }}};
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
