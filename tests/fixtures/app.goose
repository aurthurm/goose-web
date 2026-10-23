import goose_web from "../..";
import std;

// Small DSL app served through web::run; tests/integration/app.py drives it over sockets.
struct Item { id: i64, title: u8[..16], done: bool }
struct ItemIn { title: u8[..16], done: bool = false }

// Nested-struct registration: lists of Item encode through this pair.
fn web::json_put_value(out: u8[>..]&, v: Item&) -> bool { return web::json_put_fields(out, v); }

var items: Item[..8] = [];
var next_item_id: i64 = 1;

fn app(c: web::Ctx&) {
    request_id(c) { logger(c) { cors(c) {
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
