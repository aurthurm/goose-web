import goose_web from "../..";
import todo_app from "../../examples/basic/todos";
import std;

// Drives the Todo routes through the same c.routes() dispatch the server uses. The gates
// are test doubles for the server's event-capacity check and mutation hook.
var allow_mutations = false;
var mutations: i64 = 0;
var last_action: i32 = 0;
var last_id: i64 = 0;
fn permitted() -> bool { return allow_mutations; }
fn changed(request_id: i64, action: i32, id: i64) { mutations += 1; last_action = action; last_id = id; }

fn app(c: web::Ctx&) {
    c.routes() { todo::mount(c, permitted, changed); };
}
fn invoke(method: const u8[:], target: const u8[:], body: const u8[:] = "") -> web::Response {
    var out = web::response();
    var scratch = web::AppScratch { .. };
    var c = web::new_ctx(web::Request { method: method, target: target, body: body,
        raw_headers: "Content-Type: application/json\r\n" }, out, scratch);
    app(c);
    return copy(out);
}

fn test_gating_and_events() {
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
    assert(read.status == web::HTTP_OK && ::find(web::body_of(read), "\"completed\":false") >= 0);
    assert(todo::count(todo::database) == 1);
    allow_mutations = true;
    let patched = invoke(web::METHOD_PATCH, "/todos/1", "{\"completed\":true}");
    assert(patched.status == web::HTTP_OK && mutations == 2 && last_action == todo::ACTION_UPDATED);
    let deleted = invoke(web::METHOD_DELETE, "/todos/1");
    assert(deleted.status == web::HTTP_NO_CONTENT && web::body_len(deleted) == 0 && mutations == 3);
    assert(last_action == todo::ACTION_DELETED && todo::count(todo::database) == 0);
}

// Each body is checked against the route it would reach, so one table covers POST, PUT and PATCH.
fn test_body_schema() {
    assert(todo::setup(""));
    allow_mutations = true;
    let seeded = invoke(web::METHOD_POST, "/todos", "{\"title\":\"seed\"}");
    assert(seeded.status == web::HTTP_CREATED);
    let before = mutations;
    for body in ["", "{", "{\"title\":\"a\",}", "{\"title\":\"\\x\"}", "{\"title\":\"unterminated}", "{\"title\":\"a\"} false",
                 "{\"title\":\"raw\nnewline\"}", "{\"title\":NaN}", "{\"title\":\"a\xff\"}", "{\"\xff\":true}"] {
        assert(invoke(web::METHOD_POST, "/todos", body).status == web::HTTP_BAD_REQUEST);
        assert(invoke(web::METHOD_PUT, "/todos/1", body).status == web::HTTP_BAD_REQUEST);
    }
    for body in ["null", "[]", "false", "42", "\"title\"", "{}", "{\"completed\":true}", "{\"title\":null}",
                 "{\"title\":123}", "{\"title\":\"\"}", "{\"title\":\"   \"}", "{\"title\":\"\\u00a0\\u2003\"}",
                 "{\"title\":\"a\",\"completed\":0}", "{\"title\":\"a\",\"completed\":\"false\"}",
                 "{\"title\":\"a\",\"unknown\":1}", "{\"Title\":\"a\"}", "{\"title\":\"a\",\"title\":\"b\"}",
                 "{\"title\":\"a\",\"ti\\u0074le\":\"b\"}", "{\"title\":\"a\\n\"}", "{\"title\":\"a\\u0000\"}",
                 "{\"title\":\"a\\u007f\"}", "{\"title\":\"a\\ud800\"}", "{\"title\":\"a\\ud800\",\"completed\":true}"] {
        assert(invoke(web::METHOD_POST, "/todos", body).status == web::HTTP_UNPROCESSABLE_CONTENT);
    }
    assert(invoke(web::METHOD_PUT, "/todos/1", "{\"title\":\"a\"}").status == web::HTTP_UNPROCESSABLE_CONTENT);
    assert(invoke(web::METHOD_PUT, "/todos/1", "{\"completed\":true}").status == web::HTTP_UNPROCESSABLE_CONTENT);
    assert(invoke(web::METHOD_PATCH, "/todos/1", "{}").status == web::HTTP_UNPROCESSABLE_CONTENT);
    assert(invoke(web::METHOD_PATCH, "/todos/1", "{\"title\":\"\"}").status == web::HTTP_UNPROCESSABLE_CONTENT);
    assert(invoke(web::METHOD_PATCH, "/todos/1", "{\"completed\":1}").status == web::HTTP_UNPROCESSABLE_CONTENT);
    assert(mutations == before && todo::count(todo::database) == 1);
    var title: u8[todo::MAX_TITLE_BYTES + 1] = ['x'; todo::MAX_TITLE_BYTES + 1];
    var body: u8[>..] = [];
    format(body, "{\"title\":\"", title[..todo::MAX_TITLE_BYTES], "\"}");
    assert(invoke(web::METHOD_POST, "/todos", body[..]).status == web::HTTP_CREATED);
    body.clear();
    format(body, "{\"title\":\"", title, "\"}");
    assert(invoke(web::METHOD_POST, "/todos", body[..]).status == web::HTTP_UNPROCESSABLE_CONTENT);
    // The decoded title is copied into the store, so later changes to the request text cannot alter it.
    var borrowed: u8[..128] = "{\"title\":\"owned\\u0020title\"}";
    let owned = invoke(web::METHOD_POST, "/todos", borrowed[..]);
    borrowed = "destroyed";
    assert(owned.status == web::HTTP_CREATED && ::find(web::body_of(owned), "\"title\":\"owned title\"") >= 0);
}

fn test_routing_and_ids() {
    assert(todo::setup(""));
    for target in ["/todos/0", "/todos/00", "/todos/01", "/todos/+1", "/todos/-1", "/todos/1x", "/todos/9223372036854775808"] {
        assert(invoke(web::METHOD_GET, target).status == web::HTTP_UNPROCESSABLE_CONTENT);
    }
    assert(invoke(web::METHOD_GET, "/todos/999").status == web::HTTP_NOT_FOUND);
    assert(invoke(web::METHOD_GET, "/missing").status == web::HTTP_NOT_FOUND);
    let wrong = invoke(web::METHOD_OPTIONS, "/todos");
    assert(wrong.status == web::HTTP_METHOD_NOT_ALLOWED && ::find(wrong.headers[0].value, "POST") >= 0);
    let far_page = invoke(web::METHOD_GET, "/todos?offset=9223372036854775807");
    assert(far_page.status == web::HTTP_OK && ::find(web::body_of(far_page), "\"items\":[]") >= 0);
    let empty = invoke(web::METHOD_GET, "/todos");
    assert(empty.status == web::HTTP_OK && ::find(web::body_of(empty), "\"total\":0") >= 0);
}

fn main() {
    test_gating_and_events();
    test_body_schema();
    test_routing_and_ids();
    print("Todo API unit tests passed: mutation backpressure, events, routes, body schema, ids, offset overflow safety");
}
