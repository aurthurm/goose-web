import goose_web from "../..";
import std;
import os;

// A server-rendered todo app. Every page shares views/layout.html, which places the page body
// with {{> content}}, the page's own blocks, and the nav, flash and footer partials. Routes:
//   GET  /                     the list, filtered by ?filter=all|open|done
//   POST /todos                add a todo (form: title); redirects back to the list
//   GET  /todos/:id            one todo
//   GET  /todos/:id/edit       the edit form
//   POST /todos/:id/edit       save; invalid input re-renders the form with a 422 and the input
//   POST /todos/:id/toggle     flip done
//   POST /todos/:id/delete     remove
//   GET  /static/style.css     public/ is served by static_files
//   anything else              the 404 page, rendered with the layout
// Writes that change state are POSTs with the CSRF token from the form (csrf_token). Results go
// back as a flash message in the session, shown on the next page, so each action is one request
// and a redirect. The state lives in memory: a restart clears it.

const MAX_TODOS = 32;
const MAX_TITLE_BYTES = 64;
const FILTER_ALL = 0;
const FILTER_OPEN = 1;
const FILTER_DONE = 2;
// Demo secret for the signed session and CSRF tokens (at least 32 bytes). A deployment supplies its own.
const SECRET = "pages-example-demo-secret-0123456789";
// Content Security Policy for every response: only this origin's styles and images.
const CSP = "default-src 'self'; img-src 'self' data:";

struct Todo { id: i64, title: u8[..MAX_TITLE_BYTES], done: bool }
// csrf_token is read by the CSRF middleware; the form binder must still know the key.
struct NewTodo { title: u8[..MAX_TITLE_BYTES] = "", csrf_token: u8[..96] = "" }
struct EditTodo { title: u8[..MAX_TITLE_BYTES] = "", csrf_token: u8[..96] = "" }

// A row for the list. Each element of a loop sees only its own fields, so the CSRF token for the
// row's forms is copied in here.
struct TodoRow { id: i64, title: u8[..MAX_TITLE_BYTES], done: bool, csrf: u8[..96] = "" }

// Page data. Every page carries meta (layout, flash, CSRF) and nav_todos (the nav's active link).
struct ListPage {
    meta: web::PageMeta,
    nav_todos: bool = true,
    filter_all: bool = false,
    filter_open: bool = false,
    filter_done: bool = false,
    open: i64 = 0,
    done: i64 = 0,
    todos: TodoRow[..MAX_TODOS],
}
struct DetailPage { meta: web::PageMeta, nav_todos: bool = true, id: i64 = 0, title: u8[..MAX_TITLE_BYTES] = "", done: bool = false }
struct EditPage { meta: web::PageMeta, nav_todos: bool = true, id: i64 = 0, title: u8[..MAX_TITLE_BYTES] = "", has_error: bool = false, error: u8[..96] = "" }
struct NotFoundPage { meta: web::PageMeta, nav_todos: bool = false }

var todos: Todo[..MAX_TODOS] = [];
var next_id: i64 = 1;

// --- helpers --------------------------------------------------------------------------

fn session_config() -> web::SessionConfig {
    return web::SessionConfig { secret: SECRET };
}

// A title is required and must contain something other than spaces.
fn valid_title(title: const u8[:]) -> bool {
    for ch in title {
        if ch != ' ' { return true; }
    }
    return false;
}

fn find_todo(id: i64) -> i64 {
    for i in todos.len {
        if todos[i].id == id { return i; }
    }
    return -1;
}

// Filter from ?filter=; anything else (or nothing) means all.
fn list_filter(c: web::Ctx&) -> i64 {
    let raw = c.query("filter");
    if raw.status != web::HTTP_OK { return FILTER_ALL; }
    if raw.value[..] == "open" { return FILTER_OPEN; }
    if raw.value[..] == "done" { return FILTER_DONE; }
    return FILTER_ALL;
}

// Redirects to /todos/:id.
fn redirect_to_todo(c: web::Ctx&, id: i64) {
    var location: u8[>..] = [];
    location.append("/todos/");
    format(location, id);
    c.redirect(location[..], web::HTTP_SEE_OTHER);
}

// --- pages ---------------------------------------------------------------------------

fn show_list(c: web::Ctx&, views: web::Templates&, filter: i64) {
    var page = ListPage { meta: c.page_meta("Todos"), .. };
    page.filter_all = filter == FILTER_ALL;
    page.filter_open = filter == FILTER_OPEN;
    page.filter_done = filter == FILTER_DONE;
    for t in todos {
        if t.done { page.done += 1; } else { page.open += 1; }
        let shown = filter == FILTER_ALL || (filter == FILTER_OPEN && !t.done) || (filter == FILTER_DONE && t.done);
        if shown {
            var row = TodoRow { id: t.id, title: t.title, done: t.done, csrf: "" };
            row.csrf.append(page.meta.csrf_token[..]);
            page.todos.push(row);
        }
    }
    c.html_page(views, embed_file("views/layout.html"), embed_file("views/list.html"), page);
}

fn show_detail(c: web::Ctx&, views: web::Templates&) {
    let id, ok = c.param_int("id");
    guard ok else { return; }
    let at = find_todo(id);
    if at < 0 {
        show_not_found(c, views);
        return;
    }
    var page = DetailPage { meta: c.page_meta("Todo"), id: id, title: todos[at].title, done: todos[at].done, .. };
    c.html_page(views, embed_file("views/layout.html"), embed_file("views/detail.html"), page);
}

fn show_edit(c: web::Ctx&, views: web::Templates&) {
    let id, ok = c.param_int("id");
    guard ok else { return; }
    let at = find_todo(id);
    if at < 0 {
        show_not_found(c, views);
        return;
    }
    var page = EditPage { meta: c.page_meta("Edit todo"), id: id, title: todos[at].title, .. };
    c.html_page(views, embed_file("views/layout.html"), embed_file("views/edit.html"), page);
}

fn show_not_found(c: web::Ctx&, views: web::Templates&) {
    c.status(web::HTTP_NOT_FOUND);
    var page = NotFoundPage { meta: c.page_meta("Not found"), .. };
    c.html_page(views, embed_file("views/layout.html"), embed_file("views/not_found.html"), page);
}

// --- writes --------------------------------------------------------------------------

fn add_todo(c: web::Ctx&) {
    let form_value, ok = form<NewTodo>(c);
    guard ok else { return; }
    if !valid_title(form_value.title[..]) {
        c.flash("error", "Title is required");
    } else if todos.len == MAX_TODOS {
        c.flash("error", "The list is full");
    } else {
        todos.push(Todo { id: next_id, title: form_value.title, done: false });
        next_id += 1;
        c.flash("ok", "Todo added");
    }
    c.redirect("/", web::HTTP_SEE_OTHER);
}

fn save_edit(c: web::Ctx&, views: web::Templates&) {
    let id, ok = c.param_int("id");
    guard ok else { return; }
    let at = find_todo(id);
    if at < 0 {
        show_not_found(c, views);
        return;
    }
    let form_value, parsed = form<EditTodo>(c);
    guard parsed else { return; }
    if !valid_title(form_value.title[..]) {
        // Invalid input: the form comes back with what was typed, and the error beside it.
        var page = EditPage { meta: c.page_meta("Edit todo"), id: id, title: form_value.title, has_error: true, .. };
        page.error.append("Title is required: use at least one letter or digit");
        c.status(web::HTTP_UNPROCESSABLE_CONTENT);
        c.html_page(views, embed_file("views/layout.html"), embed_file("views/edit.html"), page);
        return;
    }
    todos[at].title = form_value.title;
    c.flash("ok", "Todo saved");
    redirect_to_todo(c, id);
}

fn toggle_todo(c: web::Ctx&, views: web::Templates&) {
    let id, ok = c.param_int("id");
    guard ok else { return; }
    let at = find_todo(id);
    if at < 0 {
        show_not_found(c, views);
        return;
    }
    todos[at].done = !todos[at].done;
    c.flash("ok", if todos[at].done { "Marked done" } else { "Marked open" });
    c.redirect("/", web::HTTP_SEE_OTHER);
}

fn delete_todo(c: web::Ctx&, views: web::Templates&) {
    let id, ok = c.param_int("id");
    guard ok else { return; }
    let at = find_todo(id);
    if at < 0 {
        show_not_found(c, views);
        return;
    }
    var i = at;
    while i + 1 < todos.len {
        todos[i] = todos[i + 1];
        i += 1;
    }
    todos.pop_n(1);
    c.flash("ok", "Todo deleted");
    c.redirect("/", web::HTTP_SEE_OTHER);
}

// --- routes and startup -----------------------------------------------------------------

// The middleware order: request ids and logs, security headers, the signed session (flash
// messages), then CSRF checks for writes, static files, and the routes.
fn app(c: web::Ctx&, views: web::Templates&) {
    request_id(c) { c.logger() { web::live_reload(c) {
        secure_headers(c, CSP, "") {
            session(c, session_config()) {
                csrf(c, SECRET, true) {
                    c.static_files("/static", "examples/pages/public") {
                        c.routes() {
                            c.get("/") { show_list(c, views, list_filter(c)); };
                            c.post("/todos") { add_todo(c); };
                            c.get("/todos/:id") { show_detail(c, views); };
                            c.get("/todos/:id/edit") { show_edit(c, views); };
                            c.post("/todos/:id/edit") { save_edit(c, views); };
                            c.post("/todos/:id/toggle") { toggle_todo(c, views); };
                            c.post("/todos/:id/delete") { delete_todo(c, views); };
                            c.get("/*rest") { show_not_found(c, views); };
                        };
                    };
                };
            };
        };
    }}};
}

// Checks a page with the layout and partials before the server starts, so a template mistake
// is reported at startup with the reason.
fn check_page<T>(page: const u8[:], name: const u8[:], views: web::Templates&) {
    let valid, problem = check_template<T>(embed_file("views/layout.html"), page, views);
    if !valid {
        print(name, ": ", problem[..]);
        abort(name);
    }
}

fn main() {
    let config, ok, error = web::config_from_args(args());
    if !ok { abort(error); }
    // The partials every page can include by name; see views/*.html.
    var views = web::templates();
    if !web::add_template(views, "nav", embed_file("views/_nav.html")) { abort("nav partial"); }
    if !web::add_template(views, "footer", embed_file("views/_footer.html")) { abort("footer partial"); }
    if !web::add_template(views, "todo_row", embed_file("views/_todo_row.html")) { abort("todo_row partial"); }
    check_page<ListPage>(embed_file("views/list.html"), "views/list.html", views);
    check_page<DetailPage>(embed_file("views/detail.html"), "views/detail.html", views);
    check_page<EditPage>(embed_file("views/edit.html"), "views/edit.html", views);
    check_page<NotFoundPage>(embed_file("views/not_found.html"), "views/not_found.html", views);
    print("Pages server listening on port ", config.port);
    let started = web::run(config) { c => app(c, views) };
    if !started { abort("server failed"); }
}
