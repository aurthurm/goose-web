import goose_web from "../..";
import std;
import os;

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
    let config, ok, error = web::config_from_args(args());
    if !ok { abort(error); }
    print("Hello server listening on port ", config.port);
    let started = web::run(config) { c => app(c) };
    if !started { abort("server failed"); }
}
