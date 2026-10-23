// Connections, statements and error text over the C shim (native/sqlite_shim.c).
// Every call here clears or records db.error; callers check the bool result.
namespace web;
import std;
import goose_web;

extern fn gwdb_open(path: const u8[:]) -> i32;
extern fn gwdb_close(db: i32);
extern fn gwdb_exec(db: i32, sql: const u8[:]) -> i32;
extern fn gwdb_error_copy(db: i32, out: u8[:]) -> i64;
extern fn gwdb_prepare(db: i32, sql: const u8[:]) -> i32;
extern fn gwdb_finalize(stmt: i32);
extern fn gwdb_step(stmt: i32) -> i32;
extern fn gwdb_bind_int(stmt: i32, index: i32, v: i64) -> i32;
extern fn gwdb_bind_real(stmt: i32, index: i32, v: f64) -> i32;
extern fn gwdb_bind_null(stmt: i32, index: i32) -> i32;
extern fn gwdb_bind_text(stmt: i32, index: i32, v: const u8[:]) -> i32;
extern fn gwdb_column_type(stmt: i32, col: i32) -> i32;
extern fn gwdb_column_int(stmt: i32, col: i32) -> i64;
extern fn gwdb_column_real(stmt: i32, col: i32) -> f64;
extern fn gwdb_column_len(stmt: i32, col: i32) -> i64;
extern fn gwdb_column_copy(stmt: i32, col: i32, out: u8[:]) -> i64;
extern fn gwdb_changes(db: i32) -> i64;
extern fn gwdb_last_rowid(db: i32) -> i64;

// Result codes of sqlite3_step that a caller handles; any other code is an error.
const DB_ROW = 100;
const DB_DONE = 101;
const DB_NULL_TYPE = 5;
const DB_ERROR_BYTES = 256;

// A connection handle. handle 0 means closed; error holds the last SQLite message (bounded).
struct Db { handle: i32, error: u8[..256] }

fn db_set_error(db: Db&, message: const u8[:]) {
    db.error.clear();
    let n = if message.len > db.error.cap { db.error.cap } else { message.len };
    db.error.append(message[..n]);
}

// Copies the shim's message for source (a connection handle, or 0 for open errors).
fn db_fetch_error(db: Db&, source: i32) {
    var buf: u8[>..] = [];
    buf.resize(DB_ERROR_BYTES, 0);
    let n = gwdb_error_copy(source, buf[..]);
    db.error.clear();
    let keep = if n > DB_ERROR_BYTES { DB_ERROR_BYTES } else { n };
    db.error.append(buf[..keep]);
}

// Every operation starts here: clears the previous error and refuses a closed handle.
fn db_begin(db: Db&) -> bool {
    db.error.clear();
    if db.handle == 0 {
        db_set_error(db, "database is not open");
        return false;
    }
    return true;
}

// Opens (or creates) a database file; ":memory:" is a private in-memory database.
// Files are opened in WAL mode with a 5 second busy timeout. Returns false with db_error set.
fn db_open(db: Db&, path: const u8[:]) -> bool {
    db.error.clear();
    if db.handle != 0 {
        db_set_error(db, "database is already open");
        return false;
    }
    let handle = gwdb_open(path);
    if handle == 0 {
        db_fetch_error(db, 0);
        return false;
    }
    db.handle = handle;
    return true;
}

fn db_close(db: Db&) {
    if db.handle != 0 {
        gwdb_close(db.handle);
        db.handle = 0;
    }
}

// The last SQLite message for this connection, or "" after a successful call.
fn db_error(db: Db&) -> const u8[:] {
    return db.error[..];
}

// Runs one statement that takes no values (DDL, PRAGMA, BEGIN). Values must be bound instead.
fn db_exec(db: Db&, sql: const u8[:]) -> bool {
    if !db_begin(db) { return false; }
    if gwdb_exec(db.handle, sql) == 1 { return true; }
    db_fetch_error(db, db.handle);
    return false;
}

// Rowid of the last successful INSERT on this connection.
fn db_last_rowid(db: Db&) -> i64 {
    return gwdb_last_rowid(db.handle);
}

// Rows changed by the last INSERT, UPDATE or DELETE on this connection.
fn db_changes(db: Db&) -> i64 {
    return gwdb_changes(db.handle);
}

// Prepares a single statement; 0 on failure with db_error set. Callers finalize every handle.
fn db_prepare(db: Db&, sql: const u8[:]) -> i32 {
    if !db_begin(db) { return 0; }
    let s = gwdb_prepare(db.handle, sql);
    if s == 0 { db_fetch_error(db, db.handle); }
    return s;
}

// Steps a prepared statement; returns DB_ROW, DB_DONE, or false (db_error set) through the code.
fn db_step(db: Db&, s: i32) -> i32 {
    let rc = gwdb_step(s);
    if rc != DB_ROW && rc != DB_DONE { db_fetch_error(db, db.handle); }
    return rc;
}

// Binding: each returns false with db_error set when SQLite refuses the value.
fn db_bind_int(db: Db&, s: i32, index: i32, v: i64) -> bool {
    if gwdb_bind_int(s, index, v) == 1 { return true; }
    db_fetch_error(db, db.handle);
    return false;
}

fn db_bind_real(db: Db&, s: i32, index: i32, v: f64) -> bool {
    if gwdb_bind_real(s, index, v) == 1 { return true; }
    db_fetch_error(db, db.handle);
    return false;
}

fn db_bind_null(db: Db&, s: i32, index: i32) -> bool {
    if gwdb_bind_null(s, index) == 1 { return true; }
    db_fetch_error(db, db.handle);
    return false;
}

fn db_bind_text(db: Db&, s: i32, index: i32, v: const u8[:]) -> bool {
    if gwdb_bind_text(s, index, v) == 1 { return true; }
    db_fetch_error(db, db.handle);
    return false;
}

// Reads a text column into out (a limited or growable u8 array). Text longer than
// out.cap is an error, never a silent truncation. NULL is an error: Goose fields are not null.
fn db_read_text<T>(db: Db&, s: i32, col: i32, out: T&) -> bool {
    let n = gwdb_column_len(s, col);
    if n > out.cap {
        db_set_error(db, "text column is longer than its field");
        return false;
    }
    var buf: u8[>..] = [];
    buf.resize(n, 0);
    gwdb_column_copy(s, col, buf[..]);
    out.resize(n, json_elem_default(out[..]));
    json_copy_bytes(out[..], buf[..]);
    return true;
}
