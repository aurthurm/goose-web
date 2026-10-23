import goose_web from "../..";
import std;

struct Health { status: u8[..8] }
struct Greeting { message: u8[..64] }
struct Note { text: u8[..64], pinned: bool = false }

fn app(c: web::Ctx&) {
    request_id(c) { c.logger() {
        c.routes() {
            c.get("/health") { c.json(Health { status: "ok" }); };
            c.get("/hello/:name") {
                let name = c.param("name");
                guard name.len <= 56 else { c.fail(web::HTTP_UNPROCESSABLE_CONTENT, "name_too_long", "Name must be at most 56 bytes"); return; }
                c.json(Greeting { message: str("Hello, ", name) });
            };
            c.post("/notes") {
                let note, ok = body<Note>(c);
                guard ok else { return; }
                c.status(web::HTTP_CREATED).json(note);
            };
        };
    }};
}

fn main() {
    let argv = args();
    var config = web::server_config();
    config.port = 8080;
    if argv.len > 1 {
        let value, ok = parse_int(argv[1]);
        if !ok || value < web::MIN_PORT || value > web::MAX_PORT { abort("invalid port"); }
        config.port = value as i32;
    }
    print("Hello server listening on http://127.0.0.1:", config.port);
    let started = web::run(config) { c => app(c) };
    if !started { abort("server failed"); }
}
