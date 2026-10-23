import goose_web from "../..";
import todo_app from "../../examples/basic/todos";
import std;
import json;

// The describe pass runs the routes block without bodies; body_hits proves it.
var body_hits: i64 = 0;

struct Inner { n: u8 }
// A nested struct needs a schema registration, as with the JSON codec.
fn web::json_schema_value(out: u8[>..]&, v: Inner&) { web::json_schema_fields(out, v); }

struct Shape { small: u8, label: u8[..16], tags: i32[..4], inner: Inner, flag: bool }
// flag is the only optional field, so the request schema lists the other four as required.
fn web::optional_fields(v: Shape&) -> const u8[:] { return "flag"; }

struct Pair { left: i64, right: i64 }

fn permitted() -> bool { return true; }
fn changed(request_id: i64, action: i32, id: i64) { }

fn described_app(c: web::Ctx&) {
    web::openapi(c, web::OpenApiInfo { title: "Shapes", version: "2.0", description: "" }) {
        c.routes() {
            web::summary(c, "Ping");
            web::tag(c, "probe");
            web::returns_empty(c, web::HTTP_NO_CONTENT);
            c.get("/ping") { body_hits += 1; c.text("pong"); };
            web::summary(c, "List shapes");
            web::query_params<Pair>(c);
            web::returns_list<Shape>(c, web::HTTP_OK);
            c.get("/shapes") { c.text("list"); };
            web::summary(c, "Replace a shape");
            web::accepts<Shape>(c);
            web::returns<Shape>(c, web::HTTP_CREATED);
            c.put("/shapes/:id") { body_hits += 1; c.text("put"); };
            c.any("/any") { c.text("any"); };
        };
    };
}

fn plain_app(c: web::Ctx&) {
    c.routes() {
        c.get("/ping") { c.text("pong"); };
    };
}

fn todo_app_described(c: web::Ctx&) {
    web::openapi(c, web::OpenApiInfo { title: "Goose Todo API", version: "1.0.0" }) {
        c.routes() { todo::mount(c, permitted, changed); };
    };
}

// Status and a copy of the body: the response is local, so only owned text leaves.
fn exchange<App>(target: const u8[:]) -> i32, u8[>..] {
    var response = web::response();
    var c = web::new_ctx(web::Request { method: "GET", target: target, body: "", raw_headers: "" }, response);
    App(c);
    var body: u8[>..] = [];
    body.append(web::body_of(response));
    return response.status, body;
}

// --- JSON helpers: every helper is null-safe, so a missing key just fails the assert.

fn is_text(n: json::Node?, key: u8[:], want: const u8[:]) -> bool {
    let s, ok = json::as_string(json::member(n, key));
    return ok && s == want;
}

fn int_of(n: json::Node?) -> i64 {
    let v, ok = json::as_i64(n);
    return if ok { v } else { -1 };
}

fn count_of(n: json::Node?) -> i64 {
    var count: i64 = 0;
    if n {
        json::each(n) { child => count += 1; };
    }
    return count;
}

fn has_text(list: json::Node?, want: const u8[:]) -> bool {
    var found = false;
    if list {
        json::each(list) { child =>
            let s, ok = json::as_string(child);
            if ok && s == want { found = true; }
        };
    }
    return found;
}

// A parameter object with this name and location.
fn param_named(list: json::Node?, name: const u8[:], where: const u8[:]) -> bool {
    var found = false;
    if list {
        json::each(list) { child =>
            if is_text(child, "name", name) && is_text(child, "in", where) { found = true; }
        };
    }
    return found;
}

// responses[code].content["application/json"].schema of one operation.
fn schema_of(op: json::Node?, code: u8[:]) -> json::Node? {
    return json::member(json::member(json::member(json::member(json::member(op, "responses"), code), "content"), "application/json"), "schema");
}

fn request_schema(op: json::Node?) -> json::Node? {
    return json::member(json::member(json::member(json::member(op, "requestBody"), "content"), "application/json"), "schema");
}

fn check_shapes(body: const u8[:]) {
    var text: u8[>..] = [];
    text.append(body);
    var doc: json::Node[>..] = [];
    var decoded: u8[>..] = [];
    let root, err = json::parse(text[..], doc, decoded);
    guard root else { abort(err); }
    assert(is_text(root, "openapi", "3.1.0"));
    let info = json::member(root, "info");
    assert(is_text(info, "title", "Shapes") && is_text(info, "version", "2.0"));
    let paths = json::member(root, "paths");
    // /any is match-all and undocumented; /openapi.json and /docs are never listed.
    assert(count_of(paths) == 3);
    assert(count_of(json::member(paths, "/any")) == 0);

    let ping = json::member(json::member(paths, "/ping"), "get");
    assert(is_text(ping, "summary", "Ping") && has_text(json::member(ping, "tags"), "probe"));
    let no_body = json::member(json::member(ping, "responses"), "204");
    assert(count_of(no_body) > 0 && count_of(json::member(no_body, "content")) == 0);

    let list = json::member(json::member(paths, "/shapes"), "get");
    let query = json::member(list, "parameters");
    assert(count_of(query) == 2 && param_named(query, "left", "query") && param_named(query, "right", "query"));
    let list_items = json::member(schema_of(list, "200"), "items");
    assert(is_text(schema_of(list, "200"), "type", "array"));
    let list_small = json::member(json::member(list_items, "properties"), "small");
    assert(int_of(json::member(list_small, "maximum")) == 255 && int_of(json::member(list_small, "minimum")) == 0);

    let put = json::member(json::member(paths, "/shapes/{id}"), "put");
    assert(param_named(json::member(put, "parameters"), "id", "path"));
    let req = json::member(request_schema(put), "required");
    assert(count_of(req) == 4 && has_text(req, "small") && has_text(req, "label") && has_text(req, "tags") && has_text(req, "inner"));
    assert(!has_text(req, "flag"));
    let props = json::member(request_schema(put), "properties");
    assert(int_of(json::member(json::member(props, "label"), "maxLength")) == 16);
    assert(is_text(json::member(props, "flag"), "type", "boolean"));
    let tags = json::member(props, "tags");
    assert(int_of(json::member(tags, "maxItems")) == 4);
    assert(int_of(json::member(json::member(tags, "items"), "maximum")) == 2147483647);
    let inner = json::member(props, "inner");
    assert(is_text(inner, "type", "object") && int_of(json::member(json::member(json::member(inner, "properties"), "n"), "maximum")) == 255);

    // Created response with the body schema, and the framework's error envelope by default.
    assert(count_of(schema_of(put, "201")) > 0);
    assert(count_of(json::member(json::member(put, "responses"), "400")) > 0);
    assert(count_of(json::member(json::member(put, "responses"), "404")) > 0);
    assert(count_of(json::member(json::member(put, "responses"), "415")) > 0);
    assert(count_of(json::member(json::member(put, "responses"), "422")) > 0);
    assert(count_of(json::member(json::member(put, "responses"), "500")) > 0);
    let not_allowed = json::member(json::member(put, "responses"), "405");
    assert(count_of(json::member(not_allowed, "headers")) > 0);
    assert(is_text(json::member(json::member(json::member(not_allowed, "content"), "application/json"), "schema"), "type", "object"));
}

fn check_todos(body: const u8[:]) {
    var text: u8[>..] = [];
    text.append(body);
    var doc: json::Node[>..] = [];
    var decoded: u8[>..] = [];
    let root, err = json::parse(text[..], doc, decoded);
    guard root else { abort(err); }
    assert(is_text(json::member(root, "info"), "title", "Goose Todo API"));
    let paths = json::member(root, "paths");
    assert(count_of(paths) == 2);
    let collection = json::member(paths, "/todos");
    assert(count_of(json::member(collection, "get")) > 0 && count_of(json::member(collection, "post")) > 0);
    assert(count_of(json::member(collection, "put")) == 0 && count_of(json::member(collection, "delete")) == 0);
    let item = json::member(paths, "/todos/{id}");
    assert(count_of(json::member(item, "get")) > 0 && count_of(json::member(item, "put")) > 0);
    assert(count_of(json::member(item, "patch")) > 0 && count_of(json::member(item, "delete")) > 0);
    assert(count_of(json::member(item, "post")) == 0);

    let get_list = json::member(collection, "get");
    assert(has_text(json::member(get_list, "tags"), "todos"));
    assert(count_of(json::member(get_list, "parameters")) == 3);
    assert(param_named(json::member(get_list, "parameters"), "limit", "query"));
    assert(param_named(json::member(get_list, "parameters"), "completed", "query"));
    let page = schema_of(get_list, "200");
    assert(int_of(json::member(json::member(json::member(page, "properties"), "items"), "maxItems")) == 8);
    let todo_item = json::member(json::member(json::member(page, "properties"), "items"), "items");
    assert(int_of(json::member(json::member(json::member(todo_item, "properties"), "title"), "maxLength")) == 128);

    let create = json::member(collection, "post");
    let create_req = json::member(request_schema(create), "required");
    assert(count_of(create_req) == 1 && has_text(create_req, "title"));
    assert(count_of(json::member(create, "responses")) > 0);
    assert(count_of(json::member(json::member(create, "responses"), "201")) > 0);

    let replace_req = json::member(request_schema(json::member(item, "put")), "required");
    assert(count_of(replace_req) == 2 && has_text(replace_req, "title") && has_text(replace_req, "completed"));
    assert(count_of(json::member(request_schema(json::member(item, "patch")), "required")) == 0);
    assert(count_of(json::member(json::member(json::member(item, "delete"), "responses"), "204")) > 0);
    assert(count_of(json::member(json::member(json::member(json::member(item, "delete"), "responses"), "204"), "content")) == 0);
    assert(param_named(json::member(json::member(item, "get"), "parameters"), "id", "path"));
    assert(count_of(json::member(json::member(json::member(item, "get"), "responses"), "404")) > 0);
}

fn main() {
    // Describe pass: the document is served and no route body runs.
    let spec_status, spec = exchange("/openapi.json", described_app);
    assert(spec_status == 200 && body_hits == 0);
    check_shapes(spec[..]);
    assert(spec_status == 200);

    // The docs page loads Swagger UI from a pinned CDN build and points it at the JSON path.
    let docs_status, docs = exchange("/docs", described_app);
    assert(docs_status == 200 && ::find(docs[..], "cdn.jsdelivr.net/npm/swagger-ui-dist@5.17.14") >= 0);
    assert(::find(docs[..], "url: \"/openapi.json\"") >= 0);

    // Normal requests are unaffected: the route body runs once for a real request.
    let ping_status, ping = exchange("/ping", described_app);
    assert(ping_status == 200 && ping[..] == "pong" && body_hits == 1);

    // Without web::openapi the paths are plain routes: no document, a 404.
    let plain_status, plain_body = exchange("/openapi.json", plain_app);
    assert(plain_status == 404);

    // The Todo API: paths, operations, required lists and the size bound.
    let todo_status, todo_spec = exchange("/openapi.json", todo_app_described);
    assert(todo_status == 200);
    assert(todo_status == 200 && todo_spec.len < web::DEFAULT_MAX_RESPONSE_BYTES);
    check_todos(todo_spec[..]);
    print("App OpenAPI tests passed: describe pass, annotations, schemas, docs page, Todo spec");
}
