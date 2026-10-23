import goose_web;
import .store;
import .query;
import std;
namespace todo;

const DEFAULT_DATA_FILE = "build/todos.json";
const MEMORY_OPTION = "--memory";
const MAX_DATA_PATH_BYTES = 4096;
const ACTION_CREATED = 1;
const ACTION_UPDATED = 2;
const ACTION_DELETED = 3;

// Request body. The codec tracks which keys were present (web::has), so POST requires a
// title, PUT requires both fields and PATCH requires at least one. title_valid in the
// store checks the text itself: blank, control characters and overlong titles.
struct TodoInput { title: u8[..MAX_TITLE_BYTES] = "", completed: bool = false }
// Documentation-only shapes for OpenAPI: PUT requires both fields and PATCH neither, which one
// schema cannot say, so each operation names its own struct. Decoding still uses TodoInput.
struct TodoReplace { title: u8[..MAX_TITLE_BYTES], completed: bool }
struct TodoPatch { title: u8[..MAX_TITLE_BYTES], completed: bool }
fn web::optional_fields(v: todo::TodoInput&) -> const u8[:] { return "completed"; }
fn web::optional_fields(v: todo::TodoPatch&) -> const u8[:] { return "title,completed"; }

// List envelope. The codec writes fields in declaration order.
struct TodoPage { items: Todo[..MAX_PAGE_SIZE], total: i64, limit: i64, offset: i64 }

var database = store();
var data_path: u8[..MAX_DATA_PATH_BYTES] = [];

fn setup(path: const u8[:]) -> bool {
    if path.len > MAX_DATA_PATH_BYTES { return false; }
    var fresh = store();
    if path.len > 0 {
        let loaded, ok = load(path);
        if !ok { return false; }
        fresh = loaded;
    }
    database = fresh;
    data_path = path;
    return true;
}

// Error codes for failed store operations are part of the API contract (openapi.yaml).
fn store_error(c: web::Ctx&, status: i32) {
    if status == web::HTTP_CONFLICT { c.fail(status, "store_full", "The todo store is full"); }
    else if status == web::HTTP_SERVICE_UNAVAILABLE { c.fail(status, "ids_exhausted", "No more todo IDs are available"); }
    else { c.fail(status, "invalid_payload", "Todo fields are invalid"); }
}

// The example is single-threaded. CanMutate reserves event capacity before any write.
// The candidate is saved first; only then does it replace live state and OnMutation run.
fn commit<OnMutation>(c: web::Ctx&, candidate: Store&, action: i32, id: i64) -> bool {
    if data_path.len > 0 && !save(candidate, data_path) {
        c.fail(web::HTTP_INTERNAL_SERVER_ERROR, "storage_error", "Could not save todos; the change was not applied");
        return false;
    }
    database = candidate;
    OnMutation(c.request_id, action, id);
    return true;
}

// Path ID: canonical by c.param_int (422 invalid_param), and positive by this rule.
fn item_id(c: web::Ctx&) -> i64, bool {
    let id, ok = c.param_int("id");
    if !ok { return 0, false; }
    if id == 0 { c.fail(web::HTTP_UNPROCESSABLE_CONTENT, "invalid_param", "Todo ID must be a positive integer"); return 0, false; }
    return id, true;
}

fn todo_index(c: web::Ctx&, id: i64) -> i64, bool {
    let index = find(database, id);
    if index < 0 { c.fail(web::HTTP_NOT_FOUND, "todo_not_found", "Todo not found"); return 0, false; }
    return index, true;
}

fn list_todos(c: web::Ctx&) {
    let query = parse_list_query(c.target());
    if query.status != web::HTTP_OK {
        c.fail(query.status, "invalid_query", "Use unique limit (1..8), offset (nonnegative), and completed (true/false) parameters");
        return;
    }
    var ids: i64[..MAX_TODOS] = [];
    for slot in database.slots {
        if slot.used && passes_filter(slot.item, query.completed) { ids.push(slot.item.id); }
    }
    sort(ids) { a, b => a < b };
    // Pages are computed on the sorted IDs; offset beyond the end yields an empty page.
    let start = min(query.offset, ids.len);
    let end = start + min(query.limit, ids.len - start);
    var page = TodoPage { items: [], total: ids.len, limit: query.limit, offset: query.offset };
    for i in start..end { page.items.push(database.slots[find(database, ids[i])].item); }
    c.json(page);
}

fn get_todo(c: web::Ctx&) {
    let id, ok = item_id(c);
    guard ok else { return; }
    let index, found = todo_index(c, id);
    guard found else { return; }
    c.json(database.slots[index].item);
}

fn create_todo<CanMutate, OnMutation>(c: web::Ctx&) {
    let input, result = body_result<TodoInput>(c);
    guard result.ok else { return; }
    if !web::has<TodoInput>(result, "title") { c.fail(web::HTTP_UNPROCESSABLE_CONTENT, "invalid_payload", "title is required"); return; }
    if !CanMutate() { c.fail(web::HTTP_SERVICE_UNAVAILABLE, "event_queue_full", "Required event queue is full; the change was not applied"); return; }
    var candidate = database;
    let item, status = create(candidate, input.title[..], input.completed);
    if status != web::HTTP_CREATED { store_error(c, status); return; }
    guard commit(c, candidate, ACTION_CREATED, item.id, OnMutation) else { return; }
    c.status(web::HTTP_CREATED).set(web::HEADER_LOCATION, str("/todos/", item.id)).json(item);
}

// Shared by PUT and PATCH: the change is applied to a candidate, persisted, then swapped in.
fn change_todo<CanMutate, OnMutation>(c: web::Ctx&, id: i64, title: const u8[:], completed: bool) {
    if !CanMutate() { c.fail(web::HTTP_SERVICE_UNAVAILABLE, "event_queue_full", "Required event queue is full; the change was not applied"); return; }
    var candidate = database;
    let item, status = update(candidate, id, title, completed);
    if status != web::HTTP_OK { store_error(c, status); return; }
    guard commit(c, candidate, ACTION_UPDATED, id, OnMutation) else { return; }
    c.json(item);
}

fn replace_todo<CanMutate, OnMutation>(c: web::Ctx&) {
    let id, ok = item_id(c);
    guard ok else { return; }
    let index, found = todo_index(c, id);
    guard found else { return; }
    let input, result = body_result<TodoInput>(c);
    guard result.ok else { return; }
    if !web::has<TodoInput>(result, "title") || !web::has<TodoInput>(result, "completed") {
        c.fail(web::HTTP_UNPROCESSABLE_CONTENT, "invalid_payload", "title and completed are both required"); return;
    }
    change_todo(c, id, input.title[..], input.completed, CanMutate, OnMutation);
}

fn patch_todo<CanMutate, OnMutation>(c: web::Ctx&) {
    let id, ok = item_id(c);
    guard ok else { return; }
    let index, found = todo_index(c, id);
    guard found else { return; }
    let input, result = body_result<TodoInput>(c);
    guard result.ok else { return; }
    let has_title = web::has<TodoInput>(result, "title");
    let has_completed = web::has<TodoInput>(result, "completed");
    if !has_title && !has_completed { c.fail(web::HTTP_UNPROCESSABLE_CONTENT, "invalid_payload", "Provide title or completed"); return; }
    let current = database.slots[index].item;
    let title = if has_title { input.title[..] } else { current.title[..] };
    let completed = if has_completed { input.completed } else { current.completed };
    change_todo(c, id, title, completed, CanMutate, OnMutation);
}

fn delete_todo<CanMutate, OnMutation>(c: web::Ctx&) {
    let id, ok = item_id(c);
    guard ok else { return; }
    let index, found = todo_index(c, id);
    guard found else { return; }
    if !CanMutate() { c.fail(web::HTTP_SERVICE_UNAVAILABLE, "event_queue_full", "Required event queue is full; the change was not applied"); return; }
    var candidate = database;
    remove(candidate, id);
    guard commit(c, candidate, ACTION_DELETED, id, OnMutation) else { return; }
    c.no_content();
}

// Declares the Todo routes under /todos; call it inside c.routes(). CanMutate and
// OnMutation are the application's event hooks (see server.goose).
fn mount<CanMutate, OnMutation>(c: web::Ctx&) {
    c.group("/todos") {
        web::summary(c, "List todos, 1 to 8 per page (limit defaults to 8)");
        web::query_params<TodoListParams>(c);
        web::returns<TodoPage>(c, web::HTTP_OK);
        c.get("/") { list_todos(c); };
        web::summary(c, "Create a todo");
        web::accepts<TodoInput>(c);
        web::returns<Todo>(c, web::HTTP_CREATED);
        c.post("/") { create_todo(c, CanMutate, OnMutation); };
        web::summary(c, "Get a todo");
        web::returns<Todo>(c, web::HTTP_OK);
        c.get("/:id") { get_todo(c); };
        web::summary(c, "Replace a todo (both fields required)");
        web::accepts<TodoReplace>(c);
        web::returns<Todo>(c, web::HTTP_OK);
        c.put("/:id") { replace_todo(c, CanMutate, OnMutation); };
        web::summary(c, "Update some fields of a todo");
        web::accepts<TodoPatch>(c);
        web::returns<Todo>(c, web::HTTP_OK);
        c.patch("/:id") { patch_todo(c, CanMutate, OnMutation); };
        web::summary(c, "Delete a todo");
        web::returns_empty(c, web::HTTP_NO_CONTENT);
        c.delete("/:id") { delete_todo(c, CanMutate, OnMutation); };
    };
}
