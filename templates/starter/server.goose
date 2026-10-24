// Starter application for Goose Web. Edit it, then run `python3 test.py` to exercise every route.
// The import line below is written by scripts/new_project.py, which chooses where goose_web comes from.
import goose_web from "GOOSE_WEB_SOURCE";
import std;
import os;

const MAX_NOTES = 32;
const MAX_NOTE_BYTES = 120;

struct Health { status: u8[..8] }
struct Greeting { message: u8[..80] }
struct Note { text: u8[..MAX_NOTE_BYTES], pinned: bool = false }
struct NotesPage { title: u8[..32], empty: bool, count: i64, notes: Note[..MAX_NOTES] }
struct ListQuery { limit: i64 = 10 }

// c.json_list encodes each element through this registration (api.md, "JSON responses").
fn web::json_put_value(out: u8[>..]&, v: Note&) -> bool { return web::json_put_fields(out, v); }

// In-memory storage: the notes live as long as the process does.
var notes: Note[..MAX_NOTES] = [];

fn render_home(c: web::Ctx&) {
    let page = NotesPage { title: "Notes", empty: notes.len == 0, count: notes.len, notes: notes };
    c.html_template(embed_file("views/home.html"), page);
}

// Middleware order: secure_headers wraps everything, so every response carries them.
// The policy allows the Swagger UI assets that /docs loads from the jsDelivr CDN.
fn app(c: web::Ctx&) {
    secure_headers(c, "default-src 'self'; script-src 'self' 'unsafe-inline' https://cdn.jsdelivr.net; style-src 'self' 'unsafe-inline' https://cdn.jsdelivr.net") {
    request_id(c) { c.logger() { web::live_reload(c) {
        web::openapi(c, web::OpenApiInfo { title: "Starter API", version: "0.1.0",
            description: "A small notes API built with Goose Web." }) {
            c.routes() {
                web::summary(c, "Home page listing the notes");
                c.get("/") { render_home(c); };

                web::summary(c, "Check that the server is running");
                web::returns<Health>(c, web::HTTP_OK);
                c.get("/health") { c.json(Health { status: "ok" }); };

                web::summary(c, "Greet a name taken from the path");
                web::returns<Greeting>(c, web::HTTP_OK);
                c.get("/hello/:name") {
                    let name = c.param("name");
                    guard name.len <= 56 else {
                        c.fail(web::HTTP_UNPROCESSABLE_CONTENT, "name_too_long", "Name must be at most 56 bytes");
                        return;
                    }
                    c.json(Greeting { message: str("Hello, ", name) });
                };

                web::summary(c, "List notes; limit is 1 to 32 and defaults to 10");
                web::query_params<ListQuery>(c);
                web::returns_list<Note>(c, web::HTTP_OK);
                c.get("/notes") {
                    let search, ok = query<ListQuery>(c);
                    guard ok else { return; }
                    if search.limit < 1 || search.limit > MAX_NOTES {
                        c.fail(web::HTTP_UNPROCESSABLE_CONTENT, "invalid_limit", "limit must be from 1 to 32");
                        return;
                    }
                    var shown = notes.len;
                    if search.limit < shown { shown = search.limit; }
                    c.json_list(notes[..shown]);
                };

                web::summary(c, "Create a note from a JSON body");
                web::accepts<Note>(c);
                web::returns<Note>(c, web::HTTP_CREATED);
                c.post("/notes") {
                    let note, ok = body<Note>(c);
                    guard ok else { return; }
                    if notes.len == MAX_NOTES {
                        c.fail(web::HTTP_CONFLICT, "notes_full", "The note list is full");
                        return;
                    }
                    notes.push(note);
                    c.status(web::HTTP_CREATED).json(note);
                };
            };
        };
    }}}};
}

fn main() {
    let config, ok, error = web::config_from_args(args());
    if !ok { abort(error); }
    let valid, problem = check_template<NotesPage>(embed_file("views/home.html"));
    if !valid {
        print("views/home.html: ", problem[..]);
        abort("views/home.html is not a valid template");
    }
    var settings = config;
    settings.handle_signals = true;
    print("Starter listening on http://127.0.0.1:", settings.port);
    let started = web::run(settings) { c => app(c) };
    if !started { abort("server failed"); }
}
