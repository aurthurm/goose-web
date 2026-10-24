import goose_web;
import goose_web_db;
import .models;
namespace issue_board;

var database = default<web::Db>();
var opened = false;
var database_path: u8[..4096] = "";

fn setup(path: const u8[:]) {
    if path.len == 0 || path.len > 4096 { abort("BOARD_DB_FILE must contain 1 to 4096 bytes"); }
    database_path = path;
    if !web::db_open(database, path) { abort(str("cannot open issue board database: ", web::db_error(database))); }
    if !web::db_exec(database, "PRAGMA foreign_keys = ON") { abort(str("cannot enable foreign keys: ", web::db_error(database))); }
    let steps = [
        "CREATE TABLE IF NOT EXISTS projects (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, description TEXT NOT NULL DEFAULT '')",
        "CREATE TABLE IF NOT EXISTS issues (id INTEGER PRIMARY KEY AUTOINCREMENT, project_id INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE, title TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'open')"
    ];
    if !web::migrate(database, steps) { abort(str("cannot migrate issue board database: ", web::db_error(database))); }
    web::db_close(database);
}

fn close() { if opened { web::db_close(database); opened = false; } }
fn ready(c: web::Ctx&) -> bool {
    if opened { return true; }
    if database_path.len == 0 || !web::db_open(database, database_path[..]) {
        c.fail(web::HTTP_INTERNAL_SERVER_ERROR, "database_error", "Could not open database");
        return false;
    }
    if !web::db_exec(database, "PRAGMA foreign_keys = ON") {
        c.fail(web::HTTP_INTERNAL_SERVER_ERROR, "database_error", web::db_error(database));
        web::db_close(database);
        return false;
    }
    opened = true;
    return true;
}
fn failed(c: web::Ctx&) { c.fail(web::HTTP_INTERNAL_SERVER_ERROR, "database_error", web::db_error(database)); }
fn missing(c: web::Ctx&, kind: const u8[:]) {
    if web::db_error(database).len > 0 { failed(c); }
    else if kind == "project" { c.fail(web::HTTP_NOT_FOUND, "project_not_found", "Project not found"); }
    else { c.fail(web::HTTP_NOT_FOUND, "issue_not_found", "Issue not found"); }
}
