// Query builder: a fixed-size value of up to 8 AND-ed conditions, one ORDER BY and one LIMIT.
// Values are never spliced into SQL: they are kept as SqlValue and bound as parameters, and
// column names are identifiers checked here and against fields<T> when the query runs.
//
// Builders are called as functions, web::where_eq(web::query(), "title", value), because
// UFCS chains are resolved in the caller's namespace.
namespace web;
import std;
import goose_web;
import .sqlite;

const QUERY_MAX_CONDITIONS = 8;
const QUERY_TEXT_BYTES = 256;
const QUERY_NAME_BYTES = 64;
const QUERY_ERROR_BYTES = 128;
const IDENTIFIER_MAX_BYTES = 63;

const OP_EQ = 0;
const OP_NE = 1;
const OP_LT = 2;
const OP_LE = 3;
const OP_GT = 4;
const OP_GE = 5;
const OP_LIKE = 6;

// A bound value. Text is copied into the query, so it is limited to QUERY_TEXT_BYTES.
enum SqlValue { Int { v: i64 }, Real { v: f64 }, Text { v: u8[..256] }, Null }

struct Condition { column: u8[..64], op: i32, value: SqlValue }

struct Query {
    conditions: Condition[..8],
    ordered: bool,
    descending: bool,
    order_column: u8[..64],
    limited: bool,
    limit_rows: i64,
    error: u8[..128],
}

// Plain identifiers only: [A-Za-z_][A-Za-z0-9_]{0,62}. Table, column and key names pass here.
fn identifier_valid(name: const u8[:]) -> bool {
    if name.len == 0 || name.len > IDENTIFIER_MAX_BYTES { return false; }
    for i in name.len {
        let c = name[i];
        let letter = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_';
        let digit = c >= '0' && c <= '9';
        if i == 0 {
            if !letter { return false; }
        } else if !letter && !digit {
            return false;
        }
    }
    return true;
}

fn query() -> Query { return Query { .. }; }

// Keeps the first error; later builder calls then do nothing.
fn query_fail(q: Query&, message: const u8[:]) {
    if q.error.len > 0 { return; }
    let n = if message.len > q.error.cap { q.error.cap } else { message.len };
    q.error.append(message[..n]);
}

// Converts a Goose value into a bound SqlValue. Text longer than QUERY_TEXT_BYTES is refused.
fn sql_value(v: i64) -> SqlValue, bool { return SqlValue.Int { v: v }, true; }
fn sql_value(v: i32) -> SqlValue, bool { return SqlValue.Int { v: v }, true; }
fn sql_value(v: bool) -> SqlValue, bool { return SqlValue.Int { v: if v { 1 } else { 0 } }, true; }
fn sql_value(v: f64) -> SqlValue, bool { return SqlValue.Real { v: v }, true; }
fn sql_value(v: const u8[:]) -> SqlValue, bool {
    if v.len > QUERY_TEXT_BYTES { return SqlValue.Null, false; }
    var text: u8[..256] = [];
    text.append(v);
    return SqlValue.Text { v: text }, true;
}
fn sql_value<T>(v: T&) -> SqlValue, bool { return sql_value(v[..]); }

fn add_condition(q: Query, column: const u8[:], op: i32, value: SqlValue) -> Query {
    var r = q;
    if r.error.len > 0 { return r; }
    if !identifier_valid(column) {
        query_fail(r, "invalid column name in query");
        return r;
    }
    if r.conditions.len == QUERY_MAX_CONDITIONS {
        query_fail(r, "too many conditions: at most 8 per query");
        return r;
    }
    var name: u8[..64] = [];
    name.append(column);
    r.conditions.push(Condition { column: name, op: op, value: value });
    return r;
}

fn add_where<T>(q: Query, column: const u8[:], op: i32, value: T) -> Query {
    var r = q;
    let converted, ok = sql_value(value);
    if !ok {
        query_fail(r, "query value is not supported (text is limited to 256 bytes)");
        return r;
    }
    return add_condition(r, column, op, converted);
}

fn where_eq<T>(q: Query, column: const u8[:], value: T) -> Query { return add_where(q, column, OP_EQ, value); }
fn where_ne<T>(q: Query, column: const u8[:], value: T) -> Query { return add_where(q, column, OP_NE, value); }
fn where_lt<T>(q: Query, column: const u8[:], value: T) -> Query { return add_where(q, column, OP_LT, value); }
fn where_le<T>(q: Query, column: const u8[:], value: T) -> Query { return add_where(q, column, OP_LE, value); }
fn where_gt<T>(q: Query, column: const u8[:], value: T) -> Query { return add_where(q, column, OP_GT, value); }
fn where_ge<T>(q: Query, column: const u8[:], value: T) -> Query { return add_where(q, column, OP_GE, value); }
fn where_like<T>(q: Query, column: const u8[:], pattern: T) -> Query { return add_where(q, column, OP_LIKE, pattern); }

fn order_by(q: Query, column: const u8[:], descending: bool) -> Query {
    var r = q;
    if r.error.len > 0 { return r; }
    if !identifier_valid(column) {
        query_fail(r, "invalid column name in order_by");
        return r;
    }
    r.order_column.clear();
    r.order_column.append(column);
    r.ordered = true;
    r.descending = descending;
    return r;
}

fn limit(q: Query, rows: i64) -> Query {
    var r = q;
    if r.error.len > 0 { return r; }
    if rows < 0 {
        query_fail(r, "limit must not be negative");
        return r;
    }
    r.limited = true;
    r.limit_rows = rows;
    return r;
}

fn op_text(op: i32) -> const u8[:] {
    match op {
        OP_EQ => " = ?",
        OP_NE => " <> ?",
        OP_LT => " < ?",
        OP_LE => " <= ?",
        OP_GT => " > ?",
        OP_GE => " >= ?",
        _ => " LIKE ?",
    }
}

// Appends " WHERE a = ? AND b < ?" (nothing when there are no conditions).
fn append_where(sql: u8[>..]&, q: Query&) {
    for i in q.conditions.len {
        if i == 0 { sql.append(" WHERE "); } else { sql.append(" AND "); }
        sql.append(q.conditions[i].column[..]);
        sql.append(op_text(q.conditions[i].op));
    }
}

// Appends the ORDER BY and LIMIT clauses; the LIMIT placeholder is always the last parameter.
fn append_order_limit(sql: u8[>..]&, q: Query&) {
    if q.ordered {
        sql.append(" ORDER BY ");
        sql.append(q.order_column[..]);
        if q.descending { sql.append(" DESC"); } else { sql.append(" ASC"); }
    }
    if q.limited { sql.append(" LIMIT ?"); }
}

fn bind_value(db: Db&, s: i32, index: i32, value: SqlValue) -> bool {
    match value {
        Int x => db_bind_int(db, s, index, x.v),
        Real x => db_bind_real(db, s, index, x.v),
        Text x => db_bind_text(db, s, index, x.v[..]),
        Null => db_bind_null(db, s, index),
    }
}

// Binds the conditions in order, then the LIMIT value if there is one. Returns the next index.
fn bind_query(db: Db&, s: i32, q: Query&, first: i32, with_limit: bool) -> bool {
    var index = first;
    for i in q.conditions.len {
        if !bind_value(db, s, index, q.conditions[i].value) { return false; }
        index += 1;
    }
    if with_limit && q.limited {
        return db_bind_int(db, s, index, q.limit_rows);
    }
    return true;
}
