/* libFuzzer harness for the argument handling of the SQLite shim (db/native/sqlite_shim.c). The
   input is SQL text, sometimes split so that its parts are bound as parameters. Every slice the
   shim receives is an exact-size heap copy, so AddressSanitizer reports any read or write past
   it. The database is in memory and lives for the whole run. Requires clang and libsqlite3 (see
   tests/run.py for the detection and the bounded run):

     clang -std=c11 -g -O1 -fsanitize=fuzzer,address tests/fuzz/native/sqlite_fuzz.c -lsqlite3 \
       -o build/sqlite_fuzz
     build/sqlite_fuzz -max_total_time=60 -artifact_prefix=build/ */
#include "../../../db/native/sqlite_shim.c"
#include <assert.h>
#include <stdlib.h>
#include <string.h>

static int32_t fuzz_db = 0;

/* An exact-size copy of bytes (at least one byte, so the pointer is never NULL). */
static gs_slice_u8 copy_slice(const uint8_t *bytes, size_t size) {
    uint8_t *copy = malloc(size == 0 ? 1 : size);
    assert(copy != NULL);
    if (size > 0) memcpy(copy, bytes, size);
    return (gs_slice_u8){copy, (int64_t)size};
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    if (fuzz_db == 0) {
        gs_slice_u8 path = copy_slice((const uint8_t *)":memory:", 8);
        fuzz_db = gwdb_open(path);
        free(path.data);
        assert(fuzz_db > 0);
    }
    /* Whole input as SQL: a statement, a batch or junk. Errors are reported, never crashes. */
    gs_slice_u8 sql = copy_slice(data, size);
    (void)gwdb_exec(fuzz_db, sql);
    int32_t statement = gwdb_prepare(fuzz_db, sql);
    if (statement > 0) {
        /* Bind the input as text, integer, real and NULL parameters; the first byte picks the mix. */
        size_t half = size / 2;
        gs_slice_u8 first = copy_slice(data, half);
        gs_slice_u8 second = copy_slice(data + half, size - half);
        int32_t bound = gwdb_bind_text(statement, 1, first);
        (void)bound;
        (void)gwdb_bind_int(statement, 2, size > 0 ? (int64_t)data[0] - 128 : 0);
        (void)gwdb_bind_real(statement, 3, size > 1 ? (double)data[1] / 3.0 : 0.0);
        (void)gwdb_bind_null(statement, 4);
        (void)gwdb_bind_text(statement, 5, second);
        int rc;
        int guard = 0;
        while ((rc = gwdb_step(statement)) == GWDB_ROW && guard++ < 64) {
            for (int32_t col = 0; col < 4; col++) {
                int32_t type = gwdb_column_type(statement, col);
                if (type == SQLITE_TEXT || type == SQLITE_BLOB) {
                    int64_t len = gwdb_column_len(statement, col);
                    assert(len >= 0);
                    uint8_t *out = malloc(len == 0 ? 1 : (size_t)len);
                    assert(out != NULL);
                    /* Copy into a buffer one byte short, then into an exact one: the shim copies
                       min(length, capacity) and returns the copied count. */
                    int64_t short_copy = len > 0 ? gwdb_column_copy(statement, col, (gs_slice_u8){out, len - 1}) : 0;
                    assert(short_copy <= len && short_copy >= 0);
                    int64_t full = gwdb_column_copy(statement, col, (gs_slice_u8){out, len});
                    assert(full == len);
                    free(out);
                } else if (type == SQLITE_INTEGER) {
                    (void)gwdb_column_int(statement, col);
                } else if (type == SQLITE_FLOAT) {
                    (void)gwdb_column_real(statement, col);
                }
            }
        }
        gwdb_finalize(statement);
        free(first.data);
        free(second.data);
    }
    free(sql.data);

    /* The error copy respects the buffer it is given, for a live connection and for handle 0. */
    uint8_t small[7];
    (void)gwdb_error_copy(fuzz_db, (gs_slice_u8){small, sizeof(small)});
    (void)gwdb_error_copy(0, (gs_slice_u8){small, sizeof(small)});
    (void)gwdb_error_copy(GWDB_MAX_DB + 5, (gs_slice_u8){small, 0});
    (void)gwdb_changes(fuzz_db);
    (void)gwdb_last_rowid(fuzz_db);
    return 0;
}
