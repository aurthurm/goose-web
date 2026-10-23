/* SQLite shim for the goose_web_db package.
 *
 * Goose cannot hold C pointers, so this file keeps fixed tables of sqlite3 connections and
 * prepared statements and hands Goose small integer handles (0 means none). Handles are
 * 1-based; slot 0 of the error table holds messages that have no connection (open failures
 * and calls on closed handles). Text crosses as { data, len } slices and is always bound
 * with an explicit length, so no SQL is ever built from values and no string needs a NUL.
 * Every function that fails records the SQLite message for the connection it used.
 */
#include <sqlite3.h>
#include <limits.h>
#include <stdint.h>
#include <string.h>

typedef struct {
    uint8_t *data;
    int64_t len;
} gs_slice_u8;

#define GWDB_MAX_DB 8
#define GWDB_MAX_STMT 64
#define GWDB_MAX_PATH 4096
#define GWDB_ERROR_BYTES 256
#define GWDB_BUSY_MS 5000
#define GWDB_ROW 100
#define GWDB_DONE 101

static sqlite3 *dbs[GWDB_MAX_DB + 1];
static sqlite3_stmt *stmts[GWDB_MAX_STMT + 1];
static int32_t stmt_db[GWDB_MAX_STMT + 1];
static char errors[GWDB_MAX_DB + 1][GWDB_ERROR_BYTES];
static const char empty_text[1] = "";

static void copy_error(int32_t db, const char *message) {
    size_t n = strlen(message);
    if (n >= GWDB_ERROR_BYTES) n = GWDB_ERROR_BYTES - 1;
    memcpy(errors[db], message, n);
    errors[db][n] = 0;
}

static void copy_sqlite_error(int32_t db) {
    if (db > 0 && dbs[db]) copy_error(db, sqlite3_errmsg(dbs[db]));
    else copy_error(0, "database is not open");
}

static int db_valid(int32_t db) { return db > 0 && db <= GWDB_MAX_DB && dbs[db] != NULL; }
static int stmt_valid(int32_t s) { return s > 0 && s <= GWDB_MAX_STMT && stmts[s] != NULL; }

/* One statement only: the tail after the first statement may hold whitespace and semicolons.
 * The Goose slice is not NUL-terminated, so the scan stops at its end, not at a NUL. */
static int only_one_statement(const char *tail, const char *end) {
    for (; tail < end; tail++) {
        if (*tail != ' ' && *tail != '\t' && *tail != '\n' && *tail != '\r' && *tail != ';') return 0;
    }
    return 1;
}

static int32_t prepare_into(int32_t db, gs_slice_u8 sql, sqlite3_stmt **out) {
    const char *tail = NULL;
    if (sql.len < 0 || sql.len > INT_MAX) { copy_error(db, "statement too long"); return 0; }
    if (sqlite3_prepare_v2(dbs[db], (const char *)sql.data, (int)sql.len, out, &tail) != SQLITE_OK) {
        copy_sqlite_error(db);
        *out = NULL;
        return 0;
    }
    if (*out == NULL) { copy_error(db, "empty statement"); return 0; }
    if (!only_one_statement(tail, (const char *)sql.data + sql.len)) {
        sqlite3_finalize(*out);
        *out = NULL;
        copy_error(db, "only one statement may be run at a time");
        return 0;
    }
    return 1;
}

int32_t gwdb_open(gs_slice_u8 path) {
    char name[GWDB_MAX_PATH];
    sqlite3 *conn = NULL;
    int32_t handle = 0;
    int rc;
    if (path.len < 0 || path.len >= GWDB_MAX_PATH) { copy_error(0, "database path is too long"); return 0; }
    if (path.len > 0 && memchr(path.data, 0, (size_t)path.len) != NULL) {
        copy_error(0, "database path contains a NUL byte");
        return 0;
    }
    for (int32_t i = 1; i <= GWDB_MAX_DB; i++) {
        if (!dbs[i]) { handle = i; break; }
    }
    if (handle == 0) { copy_error(0, "too many open databases"); return 0; }
    if (path.len > 0) memcpy(name, path.data, (size_t)path.len);
    name[path.len] = 0;
    rc = sqlite3_open_v2(name, &conn, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, NULL);
    if (rc != SQLITE_OK) {
        copy_error(0, conn ? sqlite3_errmsg(conn) : "cannot open database");
        if (conn) sqlite3_close(conn);
        return 0;
    }
    sqlite3_busy_timeout(conn, GWDB_BUSY_MS);
    dbs[handle] = conn;
    copy_error(handle, "");
    /* WAL lets readers proceed during a write; in-memory databases ignore the mode. */
    if (sqlite3_exec(conn, "PRAGMA journal_mode=WAL", NULL, NULL, NULL) != SQLITE_OK) {
        copy_error(0, sqlite3_errmsg(conn));
        dbs[handle] = NULL;
        sqlite3_close(conn);
        return 0;
    }
    return handle;
}

void gwdb_close(int32_t db) {
    if (!db_valid(db)) return;
    for (int32_t s = 1; s <= GWDB_MAX_STMT; s++) {
        if (stmts[s] && stmt_db[s] == db) {
            sqlite3_finalize(stmts[s]);
            stmts[s] = NULL;
        }
    }
    sqlite3_close(dbs[db]);
    dbs[db] = NULL;
    copy_error(db, "");
}

/* Runs one statement with no parameters to completion; rows are discarded. 1 on success. */
int32_t gwdb_exec(int32_t db, gs_slice_u8 sql) {
    sqlite3_stmt *st = NULL;
    int rc;
    if (!db_valid(db)) { copy_error(0, "database is not open"); return 0; }
    if (!prepare_into(db, sql, &st)) return 0;
    do {
        rc = sqlite3_step(st);
    } while (rc == SQLITE_ROW);
    sqlite3_finalize(st);
    if (rc != SQLITE_DONE) { copy_sqlite_error(db); return 0; }
    return 1;
}

/* Copies the last error message of a connection (0 = open/handle errors). Returns its length. */
int64_t gwdb_error_copy(int32_t db, gs_slice_u8 out) {
    size_t n;
    if (db < 0 || db > GWDB_MAX_DB) db = 0;
    n = strlen(errors[db]);
    if ((int64_t)n > out.len) n = (size_t)out.len;
    if (n > 0) memcpy(out.data, errors[db], n);
    return (int64_t)strlen(errors[db]);
}

int32_t gwdb_prepare(int32_t db, gs_slice_u8 sql) {
    int32_t s = 0;
    sqlite3_stmt *st = NULL;
    if (!db_valid(db)) { copy_error(0, "database is not open"); return 0; }
    for (int32_t i = 1; i <= GWDB_MAX_STMT; i++) {
        if (!stmts[i]) { s = i; break; }
    }
    if (s == 0) { copy_error(db, "too many open statements"); return 0; }
    if (!prepare_into(db, sql, &st)) return 0;
    stmts[s] = st;
    stmt_db[s] = db;
    return s;
}

void gwdb_finalize(int32_t s) {
    if (!stmt_valid(s)) return;
    sqlite3_finalize(stmts[s]);
    stmts[s] = NULL;
    stmt_db[s] = 0;
}

/* Returns the SQLite step code: 100 for a row, 101 when done, anything else is an error. */
int32_t gwdb_step(int32_t s) {
    int rc;
    if (!stmt_valid(s)) return SQLITE_MISUSE;
    rc = sqlite3_step(stmts[s]);
    if (rc != SQLITE_ROW && rc != SQLITE_DONE) copy_sqlite_error(stmt_db[s]);
    return rc;
}

/* Bind functions return 1 on success and 0 on failure, with the message recorded. */
static int32_t bind_result(int32_t s, int rc) {
    if (rc == SQLITE_OK) return 1;
    copy_sqlite_error(stmt_db[s]);
    return 0;
}

int32_t gwdb_bind_int(int32_t s, int32_t index, int64_t v) {
    if (!stmt_valid(s)) return 0;
    return bind_result(s, sqlite3_bind_int64(stmts[s], index, (sqlite3_int64)v));
}

int32_t gwdb_bind_real(int32_t s, int32_t index, double v) {
    if (!stmt_valid(s)) return 0;
    return bind_result(s, sqlite3_bind_double(stmts[s], index, v));
}

int32_t gwdb_bind_null(int32_t s, int32_t index) {
    if (!stmt_valid(s)) return 0;
    return bind_result(s, sqlite3_bind_null(stmts[s], index));
}

/* SQLITE_TRANSIENT makes SQLite copy the bytes, so the Goose slice may change afterwards. */
int32_t gwdb_bind_text(int32_t s, int32_t index, gs_slice_u8 v) {
    const char *data = (const char *)v.data;
    if (!stmt_valid(s)) return 0;
    if (v.len < 0 || v.len > INT_MAX) { copy_error(stmt_db[s], "text value is too long"); return 0; }
    /* A zero-length slice may carry a NULL pointer, which SQLite would bind as NULL. */
    if (v.len == 0) data = empty_text;
    return bind_result(s, sqlite3_bind_text(stmts[s], index, data, (int)v.len, SQLITE_TRANSIENT));
}

int32_t gwdb_column_type(int32_t s, int32_t col) {
    if (!stmt_valid(s)) return 0;
    return sqlite3_column_type(stmts[s], col);
}

int64_t gwdb_column_int(int32_t s, int32_t col) {
    if (!stmt_valid(s)) return 0;
    return (int64_t)sqlite3_column_int64(stmts[s], col);
}

double gwdb_column_real(int32_t s, int32_t col) {
    if (!stmt_valid(s)) return 0.0;
    return sqlite3_column_double(stmts[s], col);
}

/* Byte length of a text column. Call before gwdb_column_copy, which reads the same value. */
int64_t gwdb_column_len(int32_t s, int32_t col) {
    if (!stmt_valid(s)) return 0;
    sqlite3_column_text(stmts[s], col);
    return (int64_t)sqlite3_column_bytes(stmts[s], col);
}

/* Copies min(length, out.len) bytes of a text column and returns the copied count. */
int64_t gwdb_column_copy(int32_t s, int32_t col, gs_slice_u8 out) {
    const unsigned char *text;
    int64_t n;
    if (!stmt_valid(s)) return 0;
    text = sqlite3_column_text(stmts[s], col);
    n = (int64_t)sqlite3_column_bytes(stmts[s], col);
    if (n > out.len) n = out.len;
    if (n > 0 && text) memcpy(out.data, text, (size_t)n);
    return n;
}

int64_t gwdb_changes(int32_t db) {
    if (!db_valid(db)) return 0;
    return (int64_t)sqlite3_changes64(dbs[db]);
}

int64_t gwdb_last_rowid(int32_t db) {
    if (!db_valid(db)) return 0;
    return (int64_t)sqlite3_last_insert_rowid(dbs[db]);
}
