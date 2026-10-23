// SQLite layer contracts on ":memory:". Every public function is exercised at least once.
// Unknown-column aborts are programmer errors and are not run here; column_known is tested.
import goose_web from "../..";
import goose_web_db from "../../db";
import std;

struct Todo { id: i64, title: u8[..200], completed: bool }
struct Narrow { id: i64, label: u8[..4] }
struct Loose { id: i64, title: u8[..200], completed: bool }
struct Small { id: i64, small: i32 }
struct Meta { level: i32, note: u8[..16] }
struct Record { id: i64, tags: i64[..4], meta: Meta, ratio: f64, big: u64 }

fn web::db_table(v: Todo&) -> const u8[:] { "todos" }
fn web::db_table(v: Narrow&) -> const u8[:] { "narrow" }
fn web::db_table(v: Loose&) -> const u8[:] { "loose" }
fn web::db_table(v: Small&) -> const u8[:] { "small" }
fn web::db_table(v: Record&) -> const u8[:] { "records" }

// Nested struct registration: the codec pair, then the SQLite pair that stores it as JSON.
fn web::json_put_value(out: u8[>..]&, v: Meta&) -> bool { return web::json_put_fields(out, v); }
fn web::json_read_value(d: web::JsonDecoder&, out: Meta&) { web::json_read_fields(d, out); }
fn web::sql_put_value(db: web::Db&, s: i32, index: i32, v: Meta&) -> bool { return web::sql_put_json(db, s, index, v); }
fn web::sql_read_value(db: web::Db&, s: i32, col: i32, out: Meta&) -> bool { return web::sql_read_json(db, s, col, out); }

// Tuple results read through let (Goose has no .1 access on call results).
fn insert_ok<T>(db: web::Db&, item: T&) -> bool {
    let id, ok = web::insert(db, item);
    return ok;
}

fn found_ok<T>(db: web::Db&, id: i64) -> bool {
    let row, ok = web::find_row<T>(db, id);
    return ok;
}

fn open_memory(db: web::Db&) {
    assert(web::db_open(db, ":memory:"));
}

fn titles_by_id(db: web::Db&, q: web::Query) -> i64[..8] {
    var ids: i64[..8] = [];
    let ok = web::select<Todo>(db, q) { row => ids.push(row.id); };
    assert(ok);
    return ids;
}

fn test_identifiers() {
    assert(web::identifier_valid("todos"));
    assert(web::identifier_valid("_a1"));
    assert(web::identifier_valid("CamelCase_9"));
    assert(!web::identifier_valid(""));
    assert(!web::identifier_valid("1abc"));
    assert(!web::identifier_valid("a-b"));
    assert(!web::identifier_valid("a b"));
    assert(!web::identifier_valid("a;DROP TABLE t"));
    assert(!web::identifier_valid("a\"b"));
    assert(!web::identifier_valid("abcdefghij0123456789abcdefghij0123456789abcdefghij0123456789abcd"));
    assert(web::identifier_valid("abcdefghij0123456789abcdefghij0123456789abcdefghij0123456789abc"));
    assert(web::column_known<Todo>("title"));
    assert(!web::column_known<Todo>("title2"));
    assert(!web::column_known<Todo>("Title"));
}

fn test_open_close_and_exec() {
    var db = default<web::Db>();
    assert(!web::db_open(db, "build/no-such-directory-for-goose-web/x.db"));
    assert(web::db_error(db).len > 0);
    assert(db.handle == 0);
    assert(!web::db_exec(db, "SELECT 1"));
    assert(web::db_error(db) == "database is not open");
    open_memory(db);
    assert(!web::db_open(db, ":memory:"));
    assert(web::db_error(db) == "database is already open");
    assert(web::db_exec(db, "CREATE TABLE t (x INTEGER)"));
    assert(web::db_exec(db, "INSERT INTO t (x) VALUES (7)"));
    assert(web::db_changes(db) == 1);
    assert(web::db_last_rowid(db) == 1);
    assert(!web::db_exec(db, "CREATE TABLE t (x INTEGER)"));
    assert(web::db_error(db).len > 0);
    assert(!web::db_exec(db, "SELECT 1; SELECT 2"));
    assert(web::db_error(db) == "only one statement may be run at a time");
    assert(web::db_exec(db, "SELECT 1"));
    assert(web::db_error(db).len == 0);
    web::db_close(db);
    web::db_close(db);
    assert(db.handle == 0);
}

fn test_crud() {
    var db = default<web::Db>();
    open_memory(db);
    assert(web::create_table<Todo>(db));
    assert(web::create_table<Todo>(db));

    var first = Todo { id: 0, title: "first", completed: false };
    let id1, ok1 = web::insert(db, first);
    assert(ok1 && id1 == 1);
    var explicit = Todo { id: 5, title: "explicit", completed: true };
    let id5, ok5 = web::insert(db, explicit);
    assert(ok5 && id5 == 5);
    let dup, ok_dup = web::insert(db, explicit);
    assert(!ok_dup && dup == 0 && web::db_error(db).len > 0);

    let row, found = web::find_row<Todo>(db, 5);
    assert(found && row.id == 5 && row.title[..] == "explicit" && row.completed);
    let missing, found_missing = web::find_row<Todo>(db, 99);
    assert(!found_missing && web::db_error(db).len == 0);

    var changed = row;
    changed.title = "renamed";
    changed.completed = false;
    assert(web::update(db, changed));
    let again, found_again = web::find_row<Todo>(db, 5);
    assert(found_again && again.title[..] == "renamed" && !again.completed);

    var absent = Todo { id: 99, title: "x", completed: false };
    assert(!web::update(db, absent));
    assert(web::db_error(db) == "no row matches the primary key");

    assert(web::remove<Todo>(db, 1));
    assert(!web::remove<Todo>(db, 1));
    assert(web::db_error(db) == "no row matches the primary key");
    let gone, found_gone = web::find_row<Todo>(db, 1);
    assert(!found_gone);
    web::db_close(db);
}

fn test_injection_stored_literally() {
    var db = default<web::Db>();
    open_memory(db);
    assert(web::create_table<Todo>(db));
    var hostile = Todo { id: 0, title: "x'); DROP TABLE todos; --", completed: false };
    assert(insert_ok(db, hostile));
    var quoted = Todo { id: 0, title: "say \"hi\" \\ and it's", completed: true };
    assert(insert_ok(db, quoted));
    let back, found = web::find_row<Todo>(db, 1);
    assert(found && back.title[..] == "x'); DROP TABLE todos; --");
    let q = web::where_eq(web::query(), "title", "x'); DROP TABLE todos; --");
    assert(web::count<Todo>(db, q) == 1);
    let q2 = web::where_eq(web::query(), "title", "say \"hi\" \\ and it's");
    assert(web::count<Todo>(db, q2) == 1);
    assert(web::count<Todo>(db, web::query()) == 2);
    web::db_close(db);
}

fn test_queries() {
    var db = default<web::Db>();
    open_memory(db);
    assert(web::create_table<Todo>(db));
    for i in 5 {
        var t = Todo { id: 0, title: "a", completed: i % 2 == 0 };
        assert(insert_ok(db, t));
    }
    assert(web::count<Todo>(db, web::query()) == 5);
    assert(web::count<Todo>(db, web::where_eq(web::query(), "completed", true)) == 3);
    assert(web::count<Todo>(db, web::where_ne(web::query(), "completed", true)) == 2);
    assert(web::count<Todo>(db, web::where_gt(web::query(), "id", 2)) == 3);
    assert(web::count<Todo>(db, web::where_ge(web::query(), "id", 2)) == 4);
    assert(web::count<Todo>(db, web::where_lt(web::query(), "id", 2)) == 1);
    assert(web::count<Todo>(db, web::where_le(web::query(), "id", 2)) == 2);
    assert(web::count<Todo>(db, web::where_like(web::query(), "title", "a%")) == 5);
    let both = web::where_gt(web::where_eq(web::query(), "completed", false), "id", 2);
    assert(web::count<Todo>(db, both) == 1);
    assert(web::count<Todo>(db, web::limit(web::query(), 1)) == 5);

    let ascending = titles_by_id(db, web::order_by(web::query(), "id", false));
    assert(ascending.len == 5 && ascending[0] == 1 && ascending[4] == 5);
    let descending = titles_by_id(db, web::order_by(web::query(), "id", true));
    assert(descending.len == 5 && descending[0] == 5 && descending[4] == 1);
    let top_two = titles_by_id(db, web::limit(web::order_by(web::query(), "id", true), 2));
    assert(top_two.len == 2 && top_two[0] == 5 && top_two[1] == 4);
    let none = titles_by_id(db, web::limit(web::query(), 0));
    assert(none.len == 0);
    let filtered = titles_by_id(db, web::order_by(web::where_eq(web::query(), "completed", true), "id", false));
    assert(filtered.len == 3 && filtered[0] == 1 && filtered[2] == 5);
    let empty = titles_by_id(db, web::where_eq(web::query(), "title", "nothing"));
    assert(empty.len == 0 && web::db_error(db).len == 0);

    // Builder errors are reported by count and select as false or -1, never as a partial result.
    assert(web::count<Todo>(db, web::where_eq(web::query(), "bad-name", 1)) == -1);
    assert(web::db_error(db) == "invalid column name in query");
    var long_text: u8[>..] = [];
    long_text.resize(300, 'x');
    assert(web::count<Todo>(db, web::where_eq(web::query(), "title", long_text[..])) == -1);
    assert(web::db_error(db) == "query value is not supported (text is limited to 256 bytes)");
    var many = web::query();
    for i in 9 { many = web::where_eq(many, "id", i); }
    assert(web::count<Todo>(db, many) == -1);
    assert(web::db_error(db) == "too many conditions: at most 8 per query");
    assert(!web::select<Todo>(db, web::limit(web::query(), -1)) { row => assert(false); });
    web::db_close(db);
}

fn test_transactions() {
    var db = default<web::Db>();
    open_memory(db);
    assert(web::create_table<Todo>(db));
    var a = Todo { id: 1, title: "one", completed: false };
    var b = Todo { id: 2, title: "two", completed: false };
    assert(web::transaction(db) { insert_ok(db, a) && insert_ok(db, b) });
    assert(web::count<Todo>(db, web::query()) == 2);

    var c = Todo { id: 3, title: "three", completed: false };
    assert(!web::transaction(db) { insert_ok(db, c) && false });
    assert(web::count<Todo>(db, web::query()) == 2);
    assert(!found_ok<Todo>(db, 3));

    // A failing statement inside the block rolls back the earlier insert too.
    assert(!web::transaction(db) { insert_ok(db, c) && insert_ok(db, a) });
    // Read the message before any other call: every operation clears db_error first.
    assert(web::db_error(db) == "UNIQUE constraint failed: todos.id");
    assert(web::count<Todo>(db, web::query()) == 2);

    // Nested BEGIN is refused and the outer work is untouched.
    assert(!web::transaction(db) { web::transaction(db) { true } });
    assert(web::count<Todo>(db, web::query()) == 2);
    web::db_close(db);
}

fn test_migrations() {
    var db = default<web::Db>();
    open_memory(db);
    assert(web::migrate(db, ["CREATE TABLE a (x INTEGER NOT NULL)", "CREATE TABLE b (y INTEGER NOT NULL)"]));
    assert(web::migrate(db, ["CREATE TABLE a (x INTEGER NOT NULL)", "CREATE TABLE b (y INTEGER NOT NULL)"]));
    assert(web::db_exec(db, "INSERT INTO a (x) VALUES (1)"));
    assert(web::db_exec(db, "INSERT INTO b (y) VALUES (2)"));

    // A new step applies once; the earlier steps are not run again.
    assert(web::migrate(db, ["CREATE TABLE a (x INTEGER NOT NULL)", "CREATE TABLE b (y INTEGER NOT NULL)",
                             "ALTER TABLE a ADD COLUMN z INTEGER NOT NULL DEFAULT 5"]));
    assert(web::db_exec(db, "INSERT INTO a (x, z) VALUES (3, 4)"));

    // A broken step rolls back and leaves the recorded version where it was.
    assert(!web::migrate(db, ["CREATE TABLE a (x INTEGER NOT NULL)", "CREATE TABLE b (y INTEGER NOT NULL)",
                              "ALTER TABLE a ADD COLUMN z INTEGER NOT NULL DEFAULT 5",
                              "CREATE TABLE c (w INTEGER NOT NULL); NOT SQL AT ALL"]));
    assert(web::db_error(db).len > 0);
    assert(!web::db_exec(db, "SELECT w FROM c"));
    assert(web::migrate(db, ["CREATE TABLE a (x INTEGER NOT NULL)", "CREATE TABLE b (y INTEGER NOT NULL)",
                             "ALTER TABLE a ADD COLUMN z INTEGER NOT NULL DEFAULT 5",
                             "CREATE TABLE c (w INTEGER NOT NULL)"]));
    assert(web::db_exec(db, "INSERT INTO c (w) VALUES (9)"));

    // Fewer steps than applied means the database is newer than the application.
    assert(!web::migrate(db, ["CREATE TABLE a (x INTEGER NOT NULL)"]));
    assert(web::db_error(db) == "database schema is newer than this application");
    web::db_close(db);
}

fn test_nulls_text_and_ranges() {
    var db = default<web::Db>();
    open_memory(db);
    // Our tables are NOT NULL, so a NULL can only come from a table made outside this layer.
    assert(web::db_exec(db, "CREATE TABLE loose (id INTEGER PRIMARY KEY, title TEXT, completed INTEGER)"));
    assert(web::db_exec(db, "INSERT INTO loose (id, title, completed) VALUES (77, NULL, 0)"));
    assert(!found_ok<Loose>(db, 77));
    assert(web::db_error(db) == "NULL value where the field requires one");
    assert(web::create_table<Todo>(db));

    assert(web::create_table<Narrow>(db));
    assert(web::db_exec(db, "INSERT INTO narrow (id, label) VALUES (1, 'toolong')"));
    assert(!found_ok<Narrow>(db, 1));
    assert(web::db_error(db) == "text column is longer than its field");
    assert(web::db_exec(db, "INSERT INTO narrow (id, label) VALUES (2, 'four')"));
    assert(found_ok<Narrow>(db, 2));

    assert(web::create_table<Small>(db));
    assert(web::db_exec(db, "INSERT INTO small (id, small) VALUES (1, 3000000000)"));
    assert(!found_ok<Small>(db, 1));
    assert(web::db_error(db) == "integer out of range for the field");
    web::db_close(db);
}

fn test_nested_arrays_and_numbers() {
    var db = default<web::Db>();
    open_memory(db);
    assert(web::create_table<Record>(db));
    var tags: i64[..4] = [];
    tags.push(1); tags.push(-2); tags.push(3);
    var record = Record { id: 0, tags: tags, meta: Meta { level: 2, note: "hi" }, ratio: 0.5, big: 42 };
    let id, ok = web::insert(db, record);
    assert(ok);
    let back, found = web::find_row<Record>(db, id);
    assert(found && back.tags.len == 3 && back.tags[1] == -2 && back.meta.level == 2);
    assert(back.meta.note[..] == "hi" && back.ratio == 0.5 && back.big == 42);

    let huge: u64 = 18446744073709551615;
    record.big = huge;
    assert(!web::update(db, record));
    assert(web::db_error(db) == "integer is above the i64 range");

    // An array longer than its capacity is an error on read, not a silent truncation.
    assert(web::db_exec(db, "INSERT INTO records (id, tags, meta, ratio, big) VALUES (9, '[1,2,3,4,5]', '{\"level\":1,\"note\":\"\"}', 1.0, 1)"));
    assert(!found_ok<Record>(db, 9));
    assert(web::db_error(db).len > 0);
    web::db_close(db);
}

fn main() {
    test_identifiers();
    test_open_close_and_exec();
    test_crud();
    test_injection_stored_literally();
    test_queries();
    test_transactions();
    test_migrations();
    test_nulls_text_and_ranges();
    test_nested_arrays_and_numbers();
    print("db unit tests passed");
}
