# SQLite persistence

**Version:** The opt-in `db/` package is in the published `v0.6.0` release. This guide targets
the current checkout; the [v0.6.0 API](https://github.com/aurthurm/goose-web/blob/v0.6.0/docs/api.md#sqlite-webdb)
documents that release's exact contract.

SQLite is an optional package. Import `goose_web_db` and its sidecar build file, and install the
SQLite development headers and library (`libsqlite3-dev` on Debian/Ubuntu). The core framework
does not link SQLite unless this package is used.

Register a table name for each row type with `web::db_table`; `create_table<T>` creates a table
from the reflected fields. Use the query builder for values so user input remains a bound
parameter. The [SQLite Todo example](../../examples/sqlite-todos/server.goose) shows CRUD,
validation and startup in context.

```goose
import goose_web from "../goose-web";
import goose_web_db from "../goose-web/db";
import std;
import os;

struct Todo { id: i64, title: u8[..200], completed: bool }
fn web::db_table(v: Todo&) -> const u8[:] { "todos" }
fn web::json_put_value(out: u8[>..]&, v: Todo&) -> bool { return web::json_put_fields(out, v); }

var db = default<web::Db>();
var db_open = false;

fn ensure_db(c: web::Ctx&) -> bool {
    if db_open { return true; }
    if !web::db_open(db, "build/app.db") {
        c.fail(web::HTTP_INTERNAL_SERVER_ERROR, "database_error", web::db_error(db));
        return false;
    }
    db_open = true;
    return true;
}

fn app(c: web::Ctx&) {
    if !ensure_db(c) { return; }
    c.routes() {
        c.post("/todos") {
            var item = Todo { id: 0, title: "Read docs", completed: false };
            let id, inserted = web::insert(db, item);
            if !inserted { c.fail(web::HTTP_INTERNAL_SERVER_ERROR, "database_error", web::db_error(db)); return; }
            item.id = id;
            c.status(web::HTTP_CREATED).json(item);
        };
        c.get("/todos/:id") {
            let id, parsed = c.param_int("id");
            guard parsed else { return; }
            let item, found = web::find_row<Todo>(db, id);
            if !found {
                if web::db_error(db).len > 0 { c.fail(web::HTTP_INTERNAL_SERVER_ERROR, "database_error", web::db_error(db)); }
                else { c.fail(web::HTTP_NOT_FOUND, "not_found", "Todo not found"); }
                return;
            }
            c.json(item);
        };
        c.patch("/todos/:id/done") {
            let id, parsed = c.param_int("id");
            guard parsed else { return; }
            var item, found = web::find_row<Todo>(db, id);
            if !found {
                if web::db_error(db).len > 0 { c.fail(web::HTTP_INTERNAL_SERVER_ERROR, "database_error", web::db_error(db)); }
                else { c.fail(web::HTTP_NOT_FOUND, "not_found", "Todo not found"); }
                return;
            }
            item.completed = true;
            if !web::update(db, item) { c.fail(web::HTTP_INTERNAL_SERVER_ERROR, "database_error", web::db_error(db)); return; }
            c.json(item);
        };
        c.get("/open") {
            var items: Todo[..100] = [];
            let ok = web::select<Todo>(db, web::limit(web::where_eq(web::query(), "completed", false), 100)) { row =>
                items.push(row);
            };
            if !ok { c.fail(web::HTTP_INTERNAL_SERVER_ERROR, "database_error", web::db_error(db)); return; }
            c.json_list(items[..]);
        };
    };
}

fn main() {
    // Create/migrate schema before workers fork; no SQLite handle crosses fork.
    if !web::db_open(db, "build/app.db") { abort(web::db_error(db)); }
    if !web::create_table<Todo>(db) { abort(web::db_error(db)); }
    if !web::migrate(db, ["CREATE INDEX IF NOT EXISTS todos_completed ON todos(completed)"]) {
        abort(web::db_error(db));
    }
    web::db_close(db);
    var config = web::server_config();
    config.workers = 1;
    let started = web::run(config) { c => app(c) };
    if db_open { web::db_close(db); }
    if !started { abort("server failed"); }
}
```

From the repository root, compile and run with the SQLite sidecar build configuration:

```sh
mkdir -p build
goose build examples/sqlite-todos/server.goose -o build/sqlite-todos
./build/sqlite-todos 8080 build/sqlite-todos.db
```

The repository example imports its packages with `"../.."` and `"../../db"`; adjust those local
paths for your app. Its module build discovers `db/goose_web_db.build`. The database path is an
example-owned argument.

Apply schema changes with `web::migrate(db, ["ALTER TABLE ..."]);`. Migration steps are
append-only and versioned: applied steps are skipped; a database whose version exceeds the
provided step list is an error. Each step and its version bump run in a transaction.

Use `web::transaction(db) { ... }` for a group of writes. For example, after modifying `item` and
setting `obsolete_id`:

```goose
let saved = web::transaction(db) {
    web::update(db, item) && web::remove<Todo>(db, obsolete_id)
};
if !saved { c.fail(web::HTTP_INTERNAL_SERVER_ERROR, "database_error", web::db_error(db)); return; }
```

The block's final boolean commits on true and rolls back on false.
A failed statement makes the transaction fail and preserves its database error. Do not use a
nonlocal `return` inside the block, and do not nest transactions.

**Worker lifecycle matters.** Database calls are synchronous and run on the reactor thread; keep
queries and write transactions short. With pre-fork workers, do not carry an open SQLite handle
across `fork`. The example validates/creates the schema before serving, closes that handle, then
each worker lazily opens its own connection on first use. Close it during process cleanup.
SQLite is suitable for one host; concurrent workers share the file, and SQLite serializes writers.
For state that may disappear at restart, consider the bounded [shared store](../api.md#shared-store).

Details, types and error behavior: [SQLite API](../api.md#sqlite-webdb).
