import goose_web from "../..";
import todo_app from "../../examples/basic/todos";
import std;

var allow_mutations = false;
var mutations: i64 = 0;
var last_action: i32 = 0;
var last_id: i64 = 0;
fn permitted() -> bool { return allow_mutations; }
fn changed(action: i32, id: i64) { mutations += 1; last_action = action; last_id = id; }
fn request(method: const u8[:], target: const u8[:], body: const u8[:] = "") -> web::Request {
    return web::Request { method: method, target: target, body: body,
        raw_headers: "Content-Type: application/json\r\n" };
}
fn invoke(method: const u8[:], target: const u8[:], body: const u8[:] = "") -> web::Response {
    var result = web::response();
    todo::handle(request(method, target, body), result, permitted, changed);
    return result;
}
fn main() {
    assert(todo::setup(""));
    let blocked_create = invoke(web::METHOD_POST, "/todos", "{\"title\":\"First\"}");
    assert(blocked_create.status == web::HTTP_SERVICE_UNAVAILABLE);
    assert(todo::count(todo::database) == 0 && mutations == 0);
    allow_mutations = true;
    let created = invoke(web::METHOD_POST, "/todos", "{\"title\":\"First\"}");
    assert(created.status == web::HTTP_CREATED && mutations == 1);
    assert(last_action == todo::ACTION_CREATED && last_id == 1);
    assert(created.headers.len == 1 && created.headers[0].name == web::HEADER_LOCATION && created.headers[0].value == "/todos/1");
    allow_mutations = false;
    let blocked_patch = invoke(web::METHOD_PATCH, "/todos/1", "{\"completed\":true}");
    assert(blocked_patch.status == web::HTTP_SERVICE_UNAVAILABLE);
    let blocked_delete = invoke(web::METHOD_DELETE, "/todos/1");
    assert(blocked_delete.status == web::HTTP_SERVICE_UNAVAILABLE && mutations == 1);
    let read = invoke(web::METHOD_GET, "/todos/1");
    assert(read.status == web::HTTP_OK && ::find(read.body, "\"completed\":false") >= 0);
    assert(todo::count(todo::database) == 1);
    allow_mutations = true;
    let patched = invoke(web::METHOD_PATCH, "/todos/1", "{\"completed\":true}");
    assert(patched.status == web::HTTP_OK && mutations == 2 && last_action == todo::ACTION_UPDATED);
    let invalid_put = invoke(web::METHOD_PUT, "/todos/1", "{\"title\":\"Missing completed\"}");
    assert(invalid_put.status == web::HTTP_UNPROCESSABLE_CONTENT && mutations == 2);
    let invalid_id = invoke(web::METHOD_GET, "/todos/01");
    assert(invalid_id.status == web::HTTP_UNPROCESSABLE_CONTENT);
    let absent = invoke(web::METHOD_DELETE, "/todos/2");
    assert(absent.status == web::HTTP_NOT_FOUND && mutations == 2);
    let far_page = invoke(web::METHOD_GET, "/todos?offset=9223372036854775807");
    assert(far_page.status == web::HTTP_OK && ::find(far_page.body, "\"items\":[]") >= 0);
    let deleted = invoke(web::METHOD_DELETE, "/todos/1");
    assert(deleted.status == web::HTTP_NO_CONTENT && deleted.body.len == 0 && mutations == 3);
    assert(last_action == todo::ACTION_DELETED && todo::count(todo::database) == 0);
    print("Todo API unit tests passed: mutation backpressure, events, routing, schema errors, offset overflow safety");
}
