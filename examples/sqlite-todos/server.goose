import goose_web from "../..";
import goose_web_db from "../../db";
import std;
import os;

// A Todo is stored as one SQLite row: the id is the rowid, the table name comes from the
// registration below. Titles are bounded by the field capacity; longer input is a 422.
struct Todo { id: i64, title: u8[..200], completed: bool }
struct TodoInput { title: u8[..200] = "", completed: bool = false }
// PATCH takes the same keys, all optional. A separate struct so the document says so.
struct TodoPatch { title: u8[..200] = "", completed: bool = false }

const DEFAULT_DB_FILE = "build/sqlite-todos.db";
const LIST_LIMIT = 100;

fn web::db_table(v: Todo&) -> const u8[:] { "todos" }

// JSON uses `done` for the `completed` field. The SQL column keeps the field name, and
// has<TodoInput>(result, "completed") still names the field, so only the wire key changes.
fn web::json_key(v: Todo&, field: const u8[:]) -> const u8[:] {
    if field == "completed" { return "done"; }
    return field;
}
fn web::json_key(v: TodoInput&, field: const u8[:]) -> const u8[:] {
    if field == "completed" { return "done"; }
    return field;
}
fn web::json_key(v: TodoPatch&, field: const u8[:]) -> const u8[:] {
    if field == "completed" { return "done"; }
    return field;
}

// Documented as optional: a POST needs only a title, a PATCH needs neither. Names are declared names.
fn web::optional_fields(v: TodoInput&) -> const u8[:] { return "completed"; }
fn web::optional_fields(v: TodoPatch&) -> const u8[:] { return "title,completed"; }

// JSON for the list envelope: the codec needs the element registered (see docs/api.md).
fn web::json_put_value(out: u8[>..]&, v: Todo&) -> bool { return web::json_put_fields(out, v); }

var database = default<web::Db>();

// A failed call sets db_error; a missing row does not. Both kinds of "no" look the same otherwise.
fn db_failed(c: web::Ctx&) {
    c.fail(web::HTTP_INTERNAL_SERVER_ERROR, "database_error", web::db_error(database));
}

fn missing_or_failed(c: web::Ctx&) {
    if web::db_error(database).len > 0 {
        db_failed(c);
    } else {
        c.fail(web::HTTP_NOT_FOUND, "todo_not_found", "Todo not found");
    }
}

fn list_todos(c: web::Ctx&) {
    var items: Todo[..100] = [];
    let ok = web::select<Todo>(database, web::limit(web::order_by(web::query(), "id", false), LIST_LIMIT)) { row =>
        items.push(row);
    };
    if !ok { db_failed(c); return; }
    c.json_list(items[..]);
}

fn create_todo(c: web::Ctx&) {
    let input, ok = body<TodoInput>(c);
    guard ok else { return; }
    if input.title.len == 0 {
        c.fail(web::HTTP_UNPROCESSABLE_CONTENT, "invalid_payload", "title must not be empty");
        return;
    }
    var item = Todo { id: 0, title: input.title, completed: input.completed };
    let id, inserted = web::insert(database, item);
    if !inserted { db_failed(c); return; }
    item.id = id;
    c.status(web::HTTP_CREATED).json(item);
}

fn show_todo(c: web::Ctx&) {
    let id, ok = c.param_int("id");
    guard ok else { return; }
    let item, found = web::find_row<Todo>(database, id);
    if !found { missing_or_failed(c); return; }
    c.json(item);
}

// PATCH: only the keys present in the body change; the codec reports which ones they are.
fn patch_todo(c: web::Ctx&) {
    let id, ok = c.param_int("id");
    guard ok else { return; }
    let input, result = body_result<TodoInput>(c);
    guard result.ok else { return; }
    let item, found = web::find_row<Todo>(database, id);
    if !found { missing_or_failed(c); return; }
    var updated = item;
    if web::has<TodoInput>(result, "title") {
        if input.title.len == 0 {
            c.fail(web::HTTP_UNPROCESSABLE_CONTENT, "invalid_payload", "title must not be empty");
            return;
        }
        updated.title = input.title;
    }
    if web::has<TodoInput>(result, "completed") { updated.completed = input.completed; }
    if !web::update(database, updated) { db_failed(c); return; }
    c.json(updated);
}

fn delete_todo(c: web::Ctx&) {
    let id, ok = c.param_int("id");
    guard ok else { return; }
    let item, found = web::find_row<Todo>(database, id);
    if !found { missing_or_failed(c); return; }
    if !web::remove<Todo>(database, id) { db_failed(c); return; }
    c.no_content();
}

// Served at /openapi.json and /docs, generated from the routes below.
fn app(c: web::Ctx&) {
    request_id(c) { c.logger() {
        web::openapi(c, web::OpenApiInfo { title: "SQLite Todo API", version: "1.0.0",
            description: "Todos persisted in a SQLite file. The completed flag is named done on the wire." }) {
            c.routes() {
                c.group("/todos") {
                    web::summary(c, "List todos, the first 100 by id");
                    web::returns_list<Todo>(c, web::HTTP_OK);
                    c.get("/") { list_todos(c); };

                    web::summary(c, "Create a todo");
                    web::accepts<TodoInput>(c);
                    web::returns<Todo>(c, web::HTTP_CREATED);
                    c.post("/") { create_todo(c); };

                    web::summary(c, "Get a todo");
                    web::returns<Todo>(c, web::HTTP_OK);
                    c.get("/:id") { show_todo(c); };

                    web::summary(c, "Update some fields of a todo");
                    web::accepts<TodoPatch>(c);
                    web::returns<Todo>(c, web::HTTP_OK);
                    c.patch("/:id") { patch_todo(c); };

                    web::summary(c, "Delete a todo");
                    web::returns_empty(c, web::HTTP_NO_CONTENT);
                    c.delete("/:id") { delete_todo(c); };
                };
            };
        };
    }};
}

fn main() {
    let argv = args();
    if argv.len > 3 { abort("usage: server [port] [database-file]"); }
    // The port goes through the framework parser; the database file is this example's own argument.
    let config, ok, error = web::config_from_args(argv[..min(argv.len, 2)]);
    if !ok { abort(error); }
    let path = if argv.len > 2 { argv[2] } else { DEFAULT_DB_FILE };
    if !web::db_open(database, path) { abort(str("cannot open database: ", web::db_error(database))); }
    if !web::create_table<Todo>(database) { abort(str("cannot create table: ", web::db_error(database))); }
    print("SQLite Todo API listening on http://127.0.0.1:", config.port);
    let started = web::run(config) { c => app(c) };
    web::db_close(database);
    if !started { abort("server failed"); }
}
