import goose_web from "../..";
import std;
import os;

// A server-rendered todo list. GET / renders views/list.html; POST /todos takes a form
// body, adds the todo and redirects back to the list. Templates are embedded at compile
// time, and main checks them before the server starts.

const MAX_TODOS = 32;
const MAX_TITLE_BYTES = 64;

struct Todo { id: i64, title: u8[..MAX_TITLE_BYTES], done: bool }
struct NewTodo { title: u8[..MAX_TITLE_BYTES] = "" }
struct ListPage { title: u8[..32], empty: bool, count: i64, todos: Todo[..MAX_TODOS] }

var todos: Todo[..MAX_TODOS] = [];
var next_id: i64 = 1;

fn render_list(c: web::Ctx&) {
    let page = ListPage { title: "Todos", empty: todos.len == 0, count: todos.len, todos: todos };
    c.html_template(embed_file("views/list.html"), page);
}

fn app(c: web::Ctx&) {
    request_id(c) { c.logger() { web::live_reload(c) {
        c.routes() {
            c.get("/") { render_list(c); };
            c.post("/todos") {
                let form_value, ok = form<NewTodo>(c);
                guard ok else { return; }
                if form_value.title.len == 0 {
                    c.fail(web::HTTP_UNPROCESSABLE_CONTENT, "title_required", "Title is required");
                    return;
                }
                if todos.len == MAX_TODOS {
                    c.fail(web::HTTP_CONFLICT, "list_full", "The list is full");
                    return;
                }
                todos.push(Todo { id: next_id, title: form_value.title, done: false });
                next_id += 1;
                c.redirect("/", web::HTTP_SEE_OTHER);
            };
        };
    }}};
}

fn main() {
    let config, ok, error = web::config_from_args(args());
    if !ok { abort(error); }
    let valid, problem = check_template<ListPage>(embed_file("views/list.html"));
    if !valid {
        print("views/list.html: ", problem[..]);
        abort("views/list.html is not a valid template");
    }
    print("Pages server listening on port ", config.port);
    let started = web::run(config) { c => app(c) };
    if !started { abort("server failed"); }
}
