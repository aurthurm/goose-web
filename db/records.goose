// Typed records: create_table, insert, update, remove, find, select, count, migrate and
// transaction, all mapped from fields<T> and the registrations below. Contract: docs/api.md.
//
// Registration (namespace web, in the application):
//   fn web::db_table(v: Todo&) -> const u8[:] { "todos" }      required
//   fn web::db_primary(v: Todo&) -> const u8[:] { "id" }       optional, default "id"
// The primary key must be an i64 field. Zero on insert means "assign the next rowid".
//
// Column mapping: integers and bool are INTEGER (read range-checked), f32/f64 are REAL, u8[..N]
// is TEXT (longer text is an error), other arrays and nested structs are TEXT holding JSON via
// the codec. A nested struct needs the codec pair json_put_value/json_read_value plus this
// pair, which routes it through the JSON path:
//   fn web::sql_put_value(db: Db&, s: i32, index: i32, v: Inner&) -> bool { return web::sql_put_json(db, s, index, v); }
//   fn web::sql_read_value(db: Db&, s: i32, col: i32, out: Inner&) -> bool { return web::sql_read_json(db, s, col, out); }
namespace web;
import std;
import json;
import goose_web;
import .sqlite;
import .query;

const SCHEMA_TABLE = "schema_version";

// --- registration ------------------------------------------------------------------

// Default primary key name; a registration overload in the application replaces it.
fn db_primary<T>(v: T&) -> const u8[:] { return "id"; }

fn table_name<T>() -> const u8[:] {
    var v = default<T>();
    return db_table(v);
}

fn primary_name<T>() -> const u8[:] {
    var v = default<T>();
    return db_primary(v);
}

// The primary key value of a record, when the primary field is an i64.
fn key_int(v: i64&) -> i64, bool { return v, true; }
fn key_int<T>(v: T&) -> i64, bool { return 0, false; }

fn key_of<T>(v: T&) -> i64, bool {
    let key = primary_name<T>();
    const for <N, A> in fields<T> {
        if N == key { return key_int(v.A); }
    }
    return 0, false;
}

fn column_known<T>(name: const u8[:]) -> bool {
    const for <N, A> in fields<T> {
        if name == N { return true; }
    }
    return false;
}

fn field_count<T>() -> i64 {
    var n: i64 = 0;
    const for <N, A> in fields<T> { n++; }
    return n;
}

// Checks names before any SQL is built: a bad registration is reported as a false result.
fn schema_ok<T>(db: Db&) -> bool {
    if !db_begin(db) { return false; }
    if !identifier_valid(table_name<T>()) {
        db_set_error(db, "invalid table name: letters, digits and underscores, not starting with a digit");
        return false;
    }
    var names_ok = true;
    const for <N, A> in fields<T> {
        if !identifier_valid(N) { names_ok = false; }
    }
    if !names_ok {
        db_set_error(db, "invalid column name: letters, digits and underscores, not starting with a digit");
        return false;
    }
    var v = default<T>();
    let _, key_ok = key_of(v);
    if !key_ok {
        db_set_error(db, "primary key must be an i64 field named by db_primary");
        return false;
    }
    return true;
}

// A query may name only fields of T; an unknown name is a programmer error, so it aborts.
fn check_query_columns<T>(q: Query&) {
    for i in q.conditions.len {
        let name = q.conditions[i].column[..];
        if !column_known<T>(name) { abort(str("web::db: unknown column in query: ", name)); }
    }
    if q.ordered && !column_known<T>(q.order_column[..]) {
        abort(str("web::db: unknown column in order_by: ", q.order_column[..]));
    }
}

// --- column types for create_table ----------------------------------------------------

fn sql_type(v: i64&) -> const u8[:] { return "INTEGER NOT NULL"; }
fn sql_type(v: i32&) -> const u8[:] { return "INTEGER NOT NULL"; }
fn sql_type(v: i16&) -> const u8[:] { return "INTEGER NOT NULL"; }
fn sql_type(v: i8&) -> const u8[:] { return "INTEGER NOT NULL"; }
fn sql_type(v: u64&) -> const u8[:] { return "INTEGER NOT NULL"; }
fn sql_type(v: u32&) -> const u8[:] { return "INTEGER NOT NULL"; }
fn sql_type(v: u16&) -> const u8[:] { return "INTEGER NOT NULL"; }
fn sql_type(v: u8&) -> const u8[:] { return "INTEGER NOT NULL"; }
fn sql_type(v: bool&) -> const u8[:] { return "INTEGER NOT NULL"; }
fn sql_type(v: f64&) -> const u8[:] { return "REAL NOT NULL"; }
fn sql_type(v: f32&) -> const u8[:] { return "REAL NOT NULL"; }
fn sql_type<T>(v: T&) -> const u8[:] { return "TEXT NOT NULL"; }

// --- writing a field ------------------------------------------------------------------

fn sql_put_value(db: Db&, s: i32, index: i32, v: i64&) -> bool { return db_bind_int(db, s, index, v); }
fn sql_put_value(db: Db&, s: i32, index: i32, v: i32&) -> bool { return db_bind_int(db, s, index, v); }
fn sql_put_value(db: Db&, s: i32, index: i32, v: i16&) -> bool { return db_bind_int(db, s, index, v); }
fn sql_put_value(db: Db&, s: i32, index: i32, v: i8&) -> bool { return db_bind_int(db, s, index, v); }
fn sql_put_value(db: Db&, s: i32, index: i32, v: u32&) -> bool { return db_bind_int(db, s, index, v); }
fn sql_put_value(db: Db&, s: i32, index: i32, v: u16&) -> bool { return db_bind_int(db, s, index, v); }
fn sql_put_value(db: Db&, s: i32, index: i32, v: u8&) -> bool { return db_bind_int(db, s, index, v); }
fn sql_put_value(db: Db&, s: i32, index: i32, v: u64&) -> bool {
    // Compared in u64 so debug builds do not trap on the conversion of a large value.
    let max_i64: u64 = 9223372036854775807;
    if v > max_i64 {
        db_set_error(db, "integer is above the i64 range");
        return false;
    }
    return db_bind_int(db, s, index, v as i64);
}
fn sql_put_value(db: Db&, s: i32, index: i32, v: bool&) -> bool {
    return db_bind_int(db, s, index, if v { 1 } else { 0 });
}
fn sql_put_value(db: Db&, s: i32, index: i32, v: f64&) -> bool { return db_bind_real(db, s, index, v); }
fn sql_put_value(db: Db&, s: i32, index: i32, v: f32&) -> bool { return db_bind_real(db, s, index, v); }

// Text (u8 arrays) binds the bytes; other arrays bind their JSON text.
fn sql_put_seq(db: Db&, s: i32, index: i32, v: const u8[:]) -> bool {
    if !valid_utf8(v) {
        db_set_error(db, "text is not valid UTF-8");
        return false;
    }
    return db_bind_text(db, s, index, v);
}

fn sql_put_seq<E>(db: Db&, s: i32, index: i32, v: E[:]) -> bool {
    var out: u8[>..] = [];
    if !json_put_value(out, v) {
        db_set_error(db, "value cannot be encoded as JSON");
        return false;
    }
    return db_bind_text(db, s, index, out[..]);
}

fn sql_put_value<T>(db: Db&, s: i32, index: i32, v: T&) -> bool { return sql_put_seq(db, s, index, v[..]); }

// For a nested struct: the codec writes it as a JSON object.
fn sql_put_json<T>(db: Db&, s: i32, index: i32, v: T&) -> bool {
    var out: u8[>..] = [];
    if !json_put_value(out, v) {
        db_set_error(db, "value cannot be encoded as JSON");
        return false;
    }
    return db_bind_text(db, s, index, out[..]);
}

// The primary key binds NULL when it is zero, so SQLite assigns the next rowid.
fn bind_key(db: Db&, s: i32, index: i32, v: i64&) -> bool {
    if v == 0 { return db_bind_null(db, s, index); }
    return db_bind_int(db, s, index, v);
}
fn bind_key<T>(db: Db&, s: i32, index: i32, v: T&) -> bool { return sql_put_value(db, s, index, v); }

// --- reading a field ------------------------------------------------------------------

// Every field is NOT NULL in the schema; a NULL here (written outside this layer) is an error.
fn db_column_present(db: Db&, s: i32, col: i32) -> bool {
    if gwdb_column_type(s, col) == DB_NULL_TYPE {
        db_set_error(db, "NULL value where the field requires one");
        return false;
    }
    return true;
}

fn read_int_in(db: Db&, s: i32, col: i32, lo: i64, hi: i64) -> i64, bool {
    var v: i64 = 0;
    if !sql_read_value(db, s, col, v) { return 0, false; }
    if v < lo || v > hi {
        db_set_error(db, "integer out of range for the field");
        return 0, false;
    }
    return v, true;
}

fn sql_read_value(db: Db&, s: i32, col: i32, out: i64&) -> bool {
    if !db_column_present(db, s, col) { return false; }
    out = gwdb_column_int(s, col);
    return true;
}
fn sql_read_value(db: Db&, s: i32, col: i32, out: i32&) -> bool {
    let v, ok = read_int_in(db, s, col, -2147483648, 2147483647);
    if ok { out = v as i32; }
    return ok;
}
fn sql_read_value(db: Db&, s: i32, col: i32, out: i16&) -> bool {
    let v, ok = read_int_in(db, s, col, -32768, 32767);
    if ok { out = v as i16; }
    return ok;
}
fn sql_read_value(db: Db&, s: i32, col: i32, out: i8&) -> bool {
    let v, ok = read_int_in(db, s, col, -128, 127);
    if ok { out = v as i8; }
    return ok;
}
fn sql_read_value(db: Db&, s: i32, col: i32, out: u64&) -> bool {
    let v, ok = read_int_in(db, s, col, 0, 9223372036854775807);
    if ok { out = v as u64; }
    return ok;
}
fn sql_read_value(db: Db&, s: i32, col: i32, out: u32&) -> bool {
    let v, ok = read_int_in(db, s, col, 0, 4294967295);
    if ok { out = v as u32; }
    return ok;
}
fn sql_read_value(db: Db&, s: i32, col: i32, out: u16&) -> bool {
    let v, ok = read_int_in(db, s, col, 0, 65535);
    if ok { out = v as u16; }
    return ok;
}
fn sql_read_value(db: Db&, s: i32, col: i32, out: u8&) -> bool {
    let v, ok = read_int_in(db, s, col, 0, 255);
    if ok { out = v as u8; }
    return ok;
}
fn sql_read_value(db: Db&, s: i32, col: i32, out: bool&) -> bool {
    let v, ok = read_int_in(db, s, col, 0, 1);
    if ok { out = v == 1; }
    return ok;
}
fn sql_read_value(db: Db&, s: i32, col: i32, out: f64&) -> bool {
    if !db_column_present(db, s, col) { return false; }
    out = gwdb_column_real(s, col);
    return true;
}
fn sql_read_value(db: Db&, s: i32, col: i32, out: f32&) -> bool {
    var wide: f64 = 0.0;
    if !sql_read_value(db, s, col, wide) { return false; }
    out = wide as f32;
    return true;
}

// Decodes JSON text into out with the codec: syntax first, then the typed pass.
fn sql_decode_json<T>(db: Db&, text: const u8[:], out: T&) -> bool {
    var check = json::reader(text);
    json::skip(check);
    if !json::finish(check) {
        db_set_error(db, check.error);
        return false;
    }
    var d = JsonDecoder { r: json::reader(text), .. };
    json_read_value(d, out);
    if d.r.error.len > 0 {
        db_set_error(db, d.r.error);
        return false;
    }
    return true;
}

// Text columns for u8 arrays (checked against capacity); JSON for every other array.
fn sql_read_value<T>(db: Db&, s: i32, col: i32, out: T&) -> bool {
    if !db_column_present(db, s, col) { return false; }
    if json_is_bytes(out[..]) { return db_read_text(db, s, col, out); }
    var buf: u8[>..] = [];
    buf.resize(gwdb_column_len(s, col), 0);
    gwdb_column_copy(s, col, buf[..]);
    return sql_decode_json(db, buf[..], out);
}

// For a nested struct: the column holds its JSON object.
fn sql_read_json<T>(db: Db&, s: i32, col: i32, out: T&) -> bool {
    if !db_column_present(db, s, col) { return false; }
    var buf: u8[>..] = [];
    buf.resize(gwdb_column_len(s, col), 0);
    gwdb_column_copy(s, col, buf[..]);
    return sql_decode_json(db, buf[..], out);
}

// Reads all fields of a row, in declaration order (the SELECT lists them the same way).
fn read_row<T>(db: Db&, s: i32, row: T&) -> bool {
    var index: i32 = 0;
    var ok = true;
    const for <N, A> in fields<T> {
        if ok { ok = sql_read_value(db, s, index, row.A); }
        index += 1;
    }
    return ok;
}

// --- SQL text ----------------------------------------------------------------------------

fn append_columns<T>(sql: u8[>..]&) {
    var first = true;
    const for <N, A> in fields<T> {
        if !first { sql.append(", "); }
        first = false;
        sql.append(N);
    }
}

// --- table operations -------------------------------------------------------------------

// CREATE TABLE IF NOT EXISTS from fields<T>. Safe to call on every start.
fn create_table<T>(db: Db&) -> bool {
    if !schema_ok<T>(db) { return false; }
    var v = default<T>();
    let key = primary_name<T>();
    var sql: u8[>..] = [];
    sql.append("CREATE TABLE IF NOT EXISTS ");
    sql.append(table_name<T>());
    sql.append(" (");
    var first = true;
    const for <N, A> in fields<T> {
        if !first { sql.append(", "); }
        first = false;
        sql.append(N);
        sql.append(" ");
        if N == key {
            sql.append("INTEGER PRIMARY KEY");
        } else {
            sql.append(sql_type(v.A));
        }
    }
    sql.append(")");
    return db_exec(db, sql[..]);
}

// INSERT of every field; returns the rowid of the new row.
fn insert<T>(db: Db&, item: T&) -> i64, bool {
    if !schema_ok<T>(db) { return 0, false; }
    let key = primary_name<T>();
    var sql: u8[>..] = [];
    sql.append("INSERT INTO ");
    sql.append(table_name<T>());
    sql.append(" (");
    append_columns<T>(sql);
    sql.append(") VALUES (");
    for i in field_count<T>() {
        if i > 0 { sql.append(", "); }
        sql.append("?");
    }
    sql.append(")");
    let s = db_prepare(db, sql[..]);
    if s == 0 { return 0, false; }
    var index: i32 = 1;
    var ok = true;
    const for <N, A> in fields<T> {
        if ok {
            if N == key { ok = bind_key(db, s, index, item.A); } else { ok = sql_put_value(db, s, index, item.A); }
        }
        index += 1;
    }
    if !ok {
        gwdb_finalize(s);
        return 0, false;
    }
    let rc = db_step(db, s);
    gwdb_finalize(s);
    if rc != DB_DONE { return 0, false; }
    return db_last_rowid(db), true;
}

// UPDATE of every field except the key, matched by the key. False with db_error when no row matches.
fn update<T>(db: Db&, item: T&) -> bool {
    if !schema_ok<T>(db) { return false; }
    let key = primary_name<T>();
    let id, _ = key_of(item);
    var sql: u8[>..] = [];
    sql.append("UPDATE ");
    sql.append(table_name<T>());
    sql.append(" SET ");
    var first = true;
    const for <N, A> in fields<T> {
        if N != key {
            if !first { sql.append(", "); }
            first = false;
            sql.append(N);
            sql.append(" = ?");
        }
    }
    if first {
        // A table whose only column is the key: SET key = key keeps the statement valid.
        sql.append(key);
        sql.append(" = ");
        sql.append(key);
    }
    sql.append(" WHERE ");
    sql.append(key);
    sql.append(" = ?");
    let s = db_prepare(db, sql[..]);
    if s == 0 { return false; }
    var index: i32 = 1;
    var ok = true;
    const for <N, A> in fields<T> {
        if ok && N != key {
            ok = sql_put_value(db, s, index, item.A);
            index += 1;
        }
    }
    if ok { ok = db_bind_int(db, s, index, id); }
    if !ok {
        gwdb_finalize(s);
        return false;
    }
    let rc = db_step(db, s);
    gwdb_finalize(s);
    if rc != DB_DONE { return false; }
    if db_changes(db) == 0 {
        db_set_error(db, "no row matches the primary key");
        return false;
    }
    return true;
}

// DELETE by key. False with db_error when no row matches.
fn remove<T>(db: Db&, id: i64) -> bool {
    if !schema_ok<T>(db) { return false; }
    var sql: u8[>..] = [];
    sql.append("DELETE FROM ");
    sql.append(table_name<T>());
    sql.append(" WHERE ");
    sql.append(primary_name<T>());
    sql.append(" = ?");
    let s = db_prepare(db, sql[..]);
    if s == 0 { return false; }
    let bound = db_bind_int(db, s, 1, id);
    let rc = db_step(db, s);
    gwdb_finalize(s);
    if !bound || rc != DB_DONE { return false; }
    if db_changes(db) == 0 {
        db_set_error(db, "no row matches the primary key");
        return false;
    }
    return true;
}

// The row with this key. A missing row is false with an empty db_error; a failure sets db_error.
// Named find_row, not find: an unqualified find in namespace web would hide the stdlib find the
// framework itself calls.
fn find_row<T>(db: Db&, id: i64) -> T, bool {
    var row = default<T>();
    if !schema_ok<T>(db) { return row, false; }
    var sql: u8[>..] = [];
    sql.append("SELECT ");
    append_columns<T>(sql);
    sql.append(" FROM ");
    sql.append(table_name<T>());
    sql.append(" WHERE ");
    sql.append(primary_name<T>());
    sql.append(" = ?");
    let s = db_prepare(db, sql[..]);
    if s == 0 { return row, false; }
    if !db_bind_int(db, s, 1, id) {
        gwdb_finalize(s);
        return row, false;
    }
    let rc = db_step(db, s);
    var found = false;
    if rc == DB_ROW { found = read_row(db, s, row); }
    gwdb_finalize(s);
    return row, found;
}

// Calls the block with each matching row, in ORDER BY order. False when a step or a column fails
// (db_error set). The block must not return early: a return would leave the statement unfinished.
fn select<T, F>(db: Db&, q: Query) -> bool {
    if !schema_ok<T>(db) { return false; }
    if q.error.len > 0 {
        db_set_error(db, q.error[..]);
        return false;
    }
    check_query_columns<T>(q);
    var sql: u8[>..] = [];
    sql.append("SELECT ");
    append_columns<T>(sql);
    sql.append(" FROM ");
    sql.append(table_name<T>());
    append_where(sql, q);
    append_order_limit(sql, q);
    let s = db_prepare(db, sql[..]);
    if s == 0 { return false; }
    if !bind_query(db, s, q, 1, true) {
        gwdb_finalize(s);
        return false;
    }
    var ok = true;
    loop {
        let rc = db_step(db, s);
        if rc == DB_DONE { break; }
        if rc != DB_ROW {
            ok = false;
            break;
        }
        var row = default<T>();
        if !read_row(db, s, row) {
            ok = false;
            break;
        }
        F(row);
    }
    gwdb_finalize(s);
    return ok;
}

// COUNT(*) of the rows matching the conditions (order and limit are ignored). -1 on failure.
fn count<T>(db: Db&, q: Query) -> i64 {
    if !schema_ok<T>(db) { return -1; }
    if q.error.len > 0 {
        db_set_error(db, q.error[..]);
        return -1;
    }
    check_query_columns<T>(q);
    var sql: u8[>..] = [];
    sql.append("SELECT COUNT(*) FROM ");
    sql.append(table_name<T>());
    append_where(sql, q);
    let s = db_prepare(db, sql[..]);
    if s == 0 { return -1; }
    if !bind_query(db, s, q, 1, false) {
        gwdb_finalize(s);
        return -1;
    }
    let rc = db_step(db, s);
    var n: i64 = -1;
    if rc == DB_ROW { n = gwdb_column_int(s, 0); }
    gwdb_finalize(s);
    return n;
}

// Runs the block inside BEGIN/COMMIT. The block's bool decides: true commits, false rolls back.
// A return inside the block would skip COMMIT and ROLLBACK, so it must not be used there.
fn transaction<F>(db: Db&) -> bool {
    if !db_exec(db, "BEGIN") { return false; }
    let committed = F() && db_exec(db, "COMMIT");
    if committed { return true; }
    var failure: u8[..256] = [];
    failure.append(db_error(db));
    db_exec(db, "ROLLBACK");
    if failure.len > 0 { db_set_error(db, failure[..]); }
    return false;
}

fn schema_version(db: Db&) -> i64, bool {
    let s = db_prepare(db, "SELECT version FROM schema_version LIMIT 1");
    if s == 0 { return 0, false; }
    let rc = db_step(db, s);
    var version: i64 = 0;
    if rc == DB_ROW { version = gwdb_column_int(s, 0); }
    gwdb_finalize(s);
    return version, rc == DB_ROW;
}

fn set_schema_version(db: Db&, version: i64) -> bool {
    let s = db_prepare(db, "UPDATE schema_version SET version = ?");
    if s == 0 { return false; }
    let bound = db_bind_int(db, s, 1, version);
    let rc = db_step(db, s);
    gwdb_finalize(s);
    return bound && rc == DB_DONE;
}

// Applies steps in order, each in its own transaction together with its version bump. The
// database records how many steps ran, so running migrate again applies only new steps.
// Steps are append-only: changing an applied step does not re-run it.
fn migrate(db: Db&, steps: const u8[:][:]) -> bool {
    if !db_exec(db, "CREATE TABLE IF NOT EXISTS schema_version (version INTEGER NOT NULL)") { return false; }
    if !db_exec(db, "INSERT INTO schema_version (version) SELECT 0 WHERE NOT EXISTS (SELECT 1 FROM schema_version)") { return false; }
    let current, ok = schema_version(db);
    if !ok { return false; }
    if current > steps.len {
        db_set_error(db, "database schema is newer than this application");
        return false;
    }
    for i in current..steps.len {
        let applied = transaction(db) {
            db_exec(db, steps[i]) && set_schema_version(db, i + 1)
        };
        if !applied { return false; }
    }
    return true;
}
