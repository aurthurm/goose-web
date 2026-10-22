import goose_web;
import .store;
import .input;
import std;
namespace todo;

const DEFAULT_DATA_FILE = "build/todos.json";
const MEMORY_OPTION = "--memory";
const MAX_DATA_PATH_BYTES = 4096;
const ROUTE_HEALTH = 1;
const ROUTE_LIST = 2;
const ROUTE_CREATE = 3;
const ROUTE_GET = 4;
const ROUTE_REPLACE = 5;
const ROUTE_PATCH = 6;
const ROUTE_DELETE = 7;
const ACTION_CREATED = 1;
const ACTION_UPDATED = 2;
const ACTION_DELETED = 3;

var database = store();
var data_path: u8[..MAX_DATA_PATH_BYTES] = [];
var routes = web::router();

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
    routes = web::router();
    return web::add_route(routes, web::METHOD_GET, "/health", ROUTE_HEALTH) &&
           web::add_route(routes, web::METHOD_GET, "/todos", ROUTE_LIST) &&
           web::add_route(routes, web::METHOD_POST, "/todos", ROUTE_CREATE) &&
           web::add_route(routes, web::METHOD_GET, "/todos/:id", ROUTE_GET) &&
           web::add_route(routes, web::METHOD_PUT, "/todos/:id", ROUTE_REPLACE) &&
           web::add_route(routes, web::METHOD_PATCH, "/todos/:id", ROUTE_PATCH) &&
           web::add_route(routes, web::METHOD_DELETE, "/todos/:id", ROUTE_DELETE);
}

fn fail(result: web::Response&, status: i32, code: const u8[:], message: const u8[:]) {
    web::application_error(result, status, code, message);
}

fn json_request(request: web::Request, result: web::Response&) -> bool {
    let content_type = web::request_header(request, web::HEADER_CONTENT_TYPE);
    let separator = ::find(content_type, ";");
    let media_type = trim(if separator < 0 { content_type } else { content_type[..separator] });
    if !web::equal_header(media_type, web::CONTENT_TYPE_JSON) {
        fail(result, web::HTTP_UNSUPPORTED_MEDIA_TYPE, "unsupported_media_type", "Use Content-Type: application/json");
        return false;
    }
    return true;
}

fn payload_error(result: web::Response&, status: i32) {
    if status == web::HTTP_BAD_REQUEST {
        fail(result, status, "invalid_json", "Body must contain a complete JSON document");
    } else {
        fail(result, status, "invalid_payload", "Provide only title and completed with the required types and fields");
    }
}

fn write_json(result: web::Response&, text: const u8[:], status: i32 = web::HTTP_OK) {
    if text.len > web::MAX_RESPONSE_BODY_BYTES {
        fail(result, web::HTTP_INTERNAL_SERVER_ERROR, "response_too_large", "Response exceeds its configured capacity");
        return;
    }
    result.status = status;
    result.content_type = web::CONTENT_TYPE_JSON;
    result.body = text;
}

fn write_item(result: web::Response&, item: Todo, status: i32 = web::HTTP_OK) {
    var text: u8[>..] = [];
    encode_item(text, item);
    text.push('\n');
    write_json(result, text, status);
}

fn list_items(request: web::Request, result: web::Response&) {
    let options = parse_list_query(request.target);
    if options.status != web::HTTP_OK {
        fail(result, options.status, "invalid_query", str("Use unique limit (1..", MAX_PAGE_SIZE, "), offset (nonnegative), and completed (true/false) parameters"));
        return;
    }
    var ids: i64[..MAX_TODOS] = [];
    for slot in database.slots {
        if slot.used && (options.completed == FILTER_ALL ||
            (options.completed == FILTER_COMPLETED && slot.item.completed) ||
            (options.completed == FILTER_INCOMPLETE && !slot.item.completed)) { ids.push(slot.item.id); }
    }
    sort(ids) { a, b => a < b };
    let start = min(options.offset, ids.len);
    let end = start + min(options.limit, ids.len - start);
    var text: u8[>..] = [];
    text.append("{\"items\":[");
    for i in start..end {
        if i > start { text.push(','); }
        let index = find(database, ids[i]);
        encode_item(text, database.slots[index].item);
    }
    format(text, "],\"total\":", ids.len, ",\"limit\":", options.limit, ",\"offset\":", options.offset, "}\n");
    write_json(result, text);
}

// The example is single-threaded. CanMutate reserves event capacity before any
// write; OnMutation runs only after persistence and the live-state swap succeed.
fn commit<OnMutation>(candidate: Store&, action: i32, id: i64, result: web::Response&) -> bool {
    if data_path.len > 0 && !save(candidate, data_path) {
        fail(result, web::HTTP_INTERNAL_SERVER_ERROR, "storage_error", "Could not save todos; the change was not applied");
        return false;
    }
    database = candidate;
    OnMutation(action, id);
    return true;
}

fn mutation_error(result: web::Response&, status: i32) {
    if status == web::HTTP_CONFLICT { fail(result, status, "store_full", "The todo store is full"); }
    else if status == web::HTTP_SERVICE_UNAVAILABLE { fail(result, status, "ids_exhausted", "No more todo IDs are available"); }
    else { fail(result, status, "invalid_payload", "Todo fields are invalid"); }
}

fn handle<CanMutate, OnMutation>(request: web::Request, result: web::Response&) {
    let selected = web::match_route(routes, request.method, request.target);
    if selected.status == web::HTTP_NOT_FOUND {
        fail(result, selected.status, "not_found", "Route not found"); return;
    }
    if selected.status == web::HTTP_METHOD_NOT_ALLOWED {
        assert(web::set_header(result, web::HEADER_ALLOW, selected.allow));
        fail(result, selected.status, "method_not_allowed", "Method not allowed for this route"); return;
    }
    if selected.handler_id == ROUTE_HEALTH {
        write_json(result, "{\"status\":\"ok\"}\n"); return;
    }
    if selected.handler_id == ROUTE_LIST { list_items(request, result); return; }

    var id: i64 = 0;
    var index: i64 = -1;
    if selected.handler_id != ROUTE_CREATE {
        let parsed, valid = parse_id(web::path_param(selected, "id"));
        if !valid { fail(result, web::HTTP_UNPROCESSABLE_CONTENT, "invalid_id", "Todo ID must be a positive canonical decimal integer"); return; }
        id = parsed;
        index = find(database, id);
        if index < 0 { fail(result, web::HTTP_NOT_FOUND, "todo_not_found", "Todo not found"); return; }
        if selected.handler_id == ROUTE_GET { write_item(result, database.slots[index].item); return; }
    }

    var input = default<TodoInput>();
    if selected.handler_id != ROUTE_DELETE {
        if !json_request(request, result) { return; }
        let mode: i32 = if selected.handler_id == ROUTE_CREATE { INPUT_CREATE }
                   else if selected.handler_id == ROUTE_REPLACE { INPUT_REPLACE } else { INPUT_PATCH };
        input = read_input(request.body, mode);
        if input.status != web::HTTP_OK { payload_error(result, input.status); return; }
    }
    if !CanMutate() {
        fail(result, web::HTTP_SERVICE_UNAVAILABLE, "event_queue_full", "Required event queue is full; the change was not applied"); return;
    }
    var candidate = database;
    if selected.handler_id == ROUTE_CREATE {
        let item, status = create(candidate, input.title, input.completed);
        if status != web::HTTP_CREATED { mutation_error(result, status); return; }
        if !commit(candidate, ACTION_CREATED, item.id, result, OnMutation) { return; }
        assert(web::set_header(result, web::HEADER_LOCATION, str("/todos/", item.id)));
        write_item(result, item, status);
    } else if selected.handler_id == ROUTE_DELETE {
        let status = remove(candidate, id);
        if !commit(candidate, ACTION_DELETED, id, result, OnMutation) { return; }
        result.status = status;
        result.content_type = web::CONTENT_TYPE_JSON;
        result.body.clear();
    } else {
        let current = database.slots[index].item;
        let title = if input.has_title { input.title[..] } else { current.title[..] };
        let completed = if input.has_completed { input.completed } else { current.completed };
        let item, status = update(candidate, id, title, completed);
        if status != web::HTTP_OK { mutation_error(result, status); return; }
        if !commit(candidate, ACTION_UPDATED, id, result, OnMutation) { return; }
        write_item(result, item);
    }
}
