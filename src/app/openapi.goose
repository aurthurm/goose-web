import src.constants.http;
import src.constants.limits;
import src.json.codec;
import src.app.context;
import std;
import json;
namespace web;

// OpenAPI 3.1 generation from the routes block (describe pass, see routes.goose) and from
// struct reflection. Annotations are no-ops outside the describe pass, so normal requests
// never pay for them. Schemas are inline: Goose cannot reflect type names for $ref.
//
// Registration idiom (as for nested JSON structs, docs/api.md): a struct nested in another
// struct needs `fn web::json_schema_value(out: u8[>..]&, v: T&)` calling json_schema_fields.
// A struct may list fields that are optional with `fn web::optional_fields(v: T&) -> const u8[:]`
// (comma list); every other field is required.
//
// Ctx fields change only by whole-value assignment: the routes block captures c, and Goose
// does not allow shrinking c while it is live (see openapi_state.goose).

struct OpenApiInfo {
    title: const u8[:],
    version: const u8[:],
    description: const u8[:] = "",
    json_path: const u8[:] = "/openapi.json",
    docs_path: const u8[:] = "/docs",
}

const OAS_ERROR_SCHEMA = "{\"type\":\"object\",\"required\":[\"error\"],\"properties\":{\"error\":{\"type\":\"object\",\"required\":[\"code\",\"message\"],\"properties\":{\"code\":{\"type\":\"string\"},\"message\":{\"type\":\"string\"}}}}}";
const OAS_DOCS_PAGE_START = "<!doctype html>\n<html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"><title>API reference</title><link rel=\"stylesheet\" href=\"https://cdn.jsdelivr.net/npm/swagger-ui-dist@5.17.14/swagger-ui.css\"></head><body><div id=\"swagger-ui\"></div><script src=\"https://cdn.jsdelivr.net/npm/swagger-ui-dist@5.17.14/swagger-ui-bundle.js\"></script><script>window.onload = function () { SwaggerUIBundle({ url: ";
const OAS_DOCS_PAGE_END = ", dom_id: \"#swagger-ui\" }); };</script></body></html>\n";

// --- configuration and state ---------------------------------------------------------

// Copies the info and paths into Ctx. Called by openapi() before the routes block runs.
fn oas_enable(c: Ctx&, info: OpenApiInfo) {
    var cfg = OasConfig { .. };
    cfg.enabled = true;
    json_store(cfg.title, info.title);
    json_store(cfg.version, info.version);
    json_store(cfg.description, info.description);
    json_store(cfg.json_path, info.json_path);
    json_store(cfg.docs_path, info.docs_path);
    c.oas.config = cfg;
}

fn oas_reset_pending(c: Ctx&) {
    c.oas.pending = OasPending { .. };
}

fn oas_begin(c: Ctx&) {
    c.oas.op_count = 0;
    oas_reset_pending(c);
}

// Which document the request asks for: 0 none, 1 JSON, 2 docs page. Only GET and HEAD.
fn oas_kind(c: Ctx&) -> i32 {
    if !c.oas.config.enabled { return 0; }
    if c.request.method != METHOD_GET && c.request.method != METHOD_HEAD { return 0; }
    let requested = path(c);
    if requested == c.oas.config.json_path[..] { return 1; }
    if requested == c.oas.config.docs_path[..] { return 2; }
    return 0;
}

// --- schema reflection ---------------------------------------------------------------

// Scalars: the concrete by-value overloads win over the generic T& fallback, as in the codec.
fn json_schema_value(out: u8[>..]&, v: i64) {
    out.append("{\"type\":\"integer\",\"minimum\":-9223372036854775807,\"maximum\":9223372036854775807}");
}
fn json_schema_value(out: u8[>..]&, v: i32) {
    out.append("{\"type\":\"integer\",\"minimum\":-2147483648,\"maximum\":2147483647}");
}
fn json_schema_value(out: u8[>..]&, v: i16) {
    out.append("{\"type\":\"integer\",\"minimum\":-32768,\"maximum\":32767}");
}
fn json_schema_value(out: u8[>..]&, v: i8) {
    out.append("{\"type\":\"integer\",\"minimum\":-128,\"maximum\":127}");
}
fn json_schema_value(out: u8[>..]&, v: u64) {
    out.append("{\"type\":\"integer\",\"minimum\":0,\"maximum\":9223372036854775807}");
}
fn json_schema_value(out: u8[>..]&, v: u32) {
    out.append("{\"type\":\"integer\",\"minimum\":0,\"maximum\":4294967295}");
}
fn json_schema_value(out: u8[>..]&, v: u16) {
    out.append("{\"type\":\"integer\",\"minimum\":0,\"maximum\":65535}");
}
fn json_schema_value(out: u8[>..]&, v: u8) {
    out.append("{\"type\":\"integer\",\"minimum\":0,\"maximum\":255}");
}
fn json_schema_value(out: u8[>..]&, v: bool) {
    out.append("{\"type\":\"boolean\"}");
}
fn json_schema_value(out: u8[>..]&, v: f32) {
    out.append("{\"type\":\"number\"}");
}
fn json_schema_value(out: u8[>..]&, v: f64) {
    out.append("{\"type\":\"number\"}");
}

// Text fields are strings bounded by their capacity; other limited arrays are arrays.
// The slice overloads decide which: a u8 slice is text (concrete beats generic E[:]).
fn schema_seq(out: u8[>..]&, s: u8[:], cap: i64) {
    out.append("{\"type\":\"string\",\"maxLength\":");
    format(out, cap);
    out.push('}');
}
fn schema_seq<E>(out: u8[>..]&, s: E[:], cap: i64) {
    var item: E = default<E>();
    out.append("{\"type\":\"array\",\"maxItems\":");
    format(out, cap);
    out.append(",\"items\":");
    json_schema_value(out, item);
    out.push('}');
}

// Fallback for limited strings and arrays. Unregistered structs fail to compile here,
// which is what the nested-struct registration is for.
fn json_schema_value<T>(out: u8[>..]&, v: T&) {
    schema_seq(out, v[..], v.cap);
}

// Default: no optional fields, so every field is required.
fn optional_fields<T>(v: T&) -> const u8[:] { return ""; }

// Whether name occurs in a comma-separated list.
fn csv_has(list: const u8[:], name: const u8[:]) -> bool {
    var rest = list;
    loop {
        let comma = find(rest, ",");
        let item = if comma < 0 { rest } else { rest[..comma] };
        if item == name { return true; }
        if comma < 0 { return false; }
        rest = rest[comma + 1..];
    }
}

// An object schema from struct T: properties in declaration order, required unless optional.
fn json_schema_fields<T>(out: u8[>..]&, v: T&) {
    let skipped = optional_fields(v);
    var req: u8[>..] = [];
    var first = true;
    out.append("{\"type\":\"object\",\"properties\":{");
    const for <N, A> in fields<T> {
        if !first { out.push(','); }
        first = false;
        json::format_key(out, N);
        json_schema_value(out, v.A);
        if !csv_has(skipped, N) {
            if req.len > 0 { req.push(','); }
            json::format_string(req, N);
        }
    }
    out.push('}');
    if req.len > 0 {
        out.append(",\"required\":[");
        out.append(req[..]);
        out.push(']');
    }
    out.push('}');
}

// --- annotations (no-ops outside the describe pass) ----------------------------------

fn summary(c: Ctx&, text: const u8[:]) {
    if c.pass != PASS_DESCRIBE { return; }
    var p = c.oas.pending;
    json_store(p.summary, text);
    c.oas.pending = p;
}

// Overrides the default tag (the first segment of the enclosing group prefix).
fn tag(c: Ctx&, name: const u8[:]) {
    if c.pass != PASS_DESCRIBE { return; }
    var p = c.oas.pending;
    json_store(p.tag, name);
    c.oas.pending = p;
}

// requestBody (application/json) for the next route, from struct T.
fn accepts<T>(c: Ctx&) {
    if c.pass != PASS_DESCRIBE { return; }
    var sample: T = T { .. };
    var schema: u8[>..] = [];
    json_schema_fields(schema, sample);
    var p = c.oas.pending;
    p.request.clear();
    p.request.append(schema[..]);
    c.oas.pending = p;
}

// Response for one status, with the body schema of struct T.
fn returns<T>(c: Ctx&, status: i32) {
    if c.pass != PASS_DESCRIBE { return; }
    var sample: T = T { .. };
    var schema: u8[>..] = [];
    json_schema_fields(schema, sample);
    oas_add_response(c, status, schema[..]);
}

// Response for one status with an array body of struct T.
fn returns_list<T>(c: Ctx&, status: i32) {
    if c.pass != PASS_DESCRIBE { return; }
    var sample: T = T { .. };
    var item: u8[>..] = [];
    json_schema_fields(item, sample);
    var schema: u8[>..] = [];
    schema.append("{\"type\":\"array\",\"items\":");
    schema.append(item[..]);
    schema.push('}');
    oas_add_response(c, status, schema[..]);
}

// Response for one status with no body (for example 204).
fn returns_empty(c: Ctx&, status: i32) {
    if c.pass != PASS_DESCRIBE { return; }
    oas_add_response(c, status, "");
}

// Query parameters from the fields of struct T. They are optional, since the query binds
// through defaults; each field's schema comes from its type.
fn query_params<T>(c: Ctx&) {
    if c.pass != PASS_DESCRIBE { return; }
    var sample: T = T { .. };
    var item: u8[>..] = [];
    const for <N, A> in fields<T> {
        if item.len > 0 { item.push(','); }
        item.append("{\"name\":");
        json::format_string(item, N);
        item.append(",\"in\":\"query\",\"required\":false,\"schema\":");
        json_schema_value(item, sample.A);
        item.push('}');
    }
    var p = c.oas.pending;
    if p.params.len > 0 && item.len > 0 { p.params.push(','); }
    p.params.append(item[..]);
    c.oas.pending = p;
}

// --- building operations (called from route_add in the describe pass) ---------------

fn oas_reason(status: i32) -> const u8[:] {
    if status == HTTP_OK { return "OK"; }
    if status == HTTP_CREATED { return "Created"; }
    if status == HTTP_NO_CONTENT { return "No Content"; }
    return "Response";
}

fn oas_add_response(c: Ctx&, status: i32, schema: const u8[:]) {
    // Built in a growable buffer: the formatters need one, and the fragment is then appended.
    var item: u8[>..] = [];
    let key = str(status);
    json::format_key(item, key[..]);
    item.append("{\"description\":");
    json::format_string(item, oas_reason(status));
    if schema.len > 0 {
        item.append(",\"content\":{\"application/json\":{\"schema\":");
        item.append(schema);
        item.append("}}");
    }
    item.push('}');
    var p = c.oas.pending;
    if p.responses.len > 0 { p.responses.push(','); }
    p.responses.append(item[..]);
    c.oas.pending = p;
}

// The framework's error envelope for one status, unless the route declared that status.
fn oas_default_error(out: u8[>..]&, declared: const u8[:], code: const u8[:], reason: const u8[:], allow: bool) {
    let needle = str("\"", code, "\":");
    if find(declared, needle[..]) >= 0 { return; }
    if out.len > 0 { out.push(','); }
    json::format_key(out, code);
    out.append("{\"description\":");
    json::format_string(out, reason);
    if allow {
        out.append(",\"headers\":{\"Allow\":{\"schema\":{\"type\":\"string\"}}}");
    }
    out.append(",\"content\":{\"application/json\":{\"schema\":");
    out.append(OAS_ERROR_SCHEMA);
    out.append("}}}");
}

fn first_segment(p: const u8[:]) -> const u8[:] {
    var start: i64 = 0;
    while start < p.len && p[start] == '/' { start += 1; }
    var end = start;
    while end < p.len && p[end] != '/' { end += 1; }
    return p[start..end];
}

// {"name":..,"in":"path","required":true,"schema":{"type":"string"}} for one path parameter.
fn oas_path_param(out: u8[>..]&, name: const u8[:]) {
    out.append("{\"name\":");
    json::format_string(out, name);
    out.append(",\"in\":\"path\",\"required\":true,\"schema\":{\"type\":\"string\"}}");
}

// Writes one operation object (the value under its method key) into out.
fn oas_write_operation(c: Ctx&, out: u8[>..]&, path_params: const u8[:]) {
    out.push('{');
    if c.oas.pending.tag.len > 0 {
        out.append("\"tags\":[");
        json::format_string(out, c.oas.pending.tag[..]);
        out.append("],");
    } else if c.prefix_count > 0 {
        let segment = first_segment(c.prefixes[0]);
        if segment.len > 0 {
            out.append("\"tags\":[");
            json::format_string(out, segment);
            out.append("],");
        }
    }
    if c.oas.pending.summary.len > 0 {
        out.append("\"summary\":");
        json::format_string(out, c.oas.pending.summary[..]);
        out.push(',');
    }
    out.append("\"parameters\":[");
    out.append(path_params);
    if path_params.len > 0 && c.oas.pending.params.len > 0 { out.push(','); }
    out.append(c.oas.pending.params[..]);
    out.push(']');
    if c.oas.pending.request.len > 0 {
        out.append(",\"requestBody\":{\"required\":true,\"content\":{\"application/json\":{\"schema\":");
        out.append(c.oas.pending.request[..]);
        out.append("}}}");
    }
    var responses: u8[>..] = [];
    responses.append(c.oas.pending.responses[..]);
    let declared = c.oas.pending.responses[..];
    oas_default_error(responses, declared, "400", "Bad Request", false);
    oas_default_error(responses, declared, "404", "Not Found", false);
    oas_default_error(responses, declared, "405", "Method Not Allowed", true);
    oas_default_error(responses, declared, "415", "Unsupported Media Type", false);
    oas_default_error(responses, declared, "422", "Unprocessable Content", false);
    oas_default_error(responses, declared, "500", "Internal Server Error", false);
    out.append(",\"responses\":{");
    out.append(responses[..]);
    out.append("}}");
}

// Adds one operation for method and pattern (prefix already joined, ":id" still present).
// The caller skips the match-all method, which has no OpenAPI form.
fn oas_add_operation(c: Ctx&, method: const u8[:], pattern: const u8[:]) {
    if c.oas.op_count >= MAX_ROUTES { abort("too many OpenAPI operations"); }
    var verb: u8[..8] = [];
    for ch in method {
        verb.push(if ch >= 'A' && ch <= 'Z' { ch | 32 } else { ch });
    }
    // The path is written as OpenAPI expects: ":id" becomes "{id}", and each becomes a parameter.
    let path_start = c.oas.text.len;
    var params: u8[>..] = [];
    var i: i64 = 0;
    while i < pattern.len {
        // :name and *name (a wildcard, which takes the rest of the path) both render as {name}.
        if (pattern[i] == ':' || pattern[i] == '*') && (i == 0 || pattern[i - 1] == '/') {
            var end = i + 1;
            while end < pattern.len && pattern[end] != '/' { end += 1; }
            let name = pattern[i + 1..end];
            c.oas.text.push('{');
            c.oas.text.append(name);
            c.oas.text.push('}');
            if params.len > 0 { params.push(','); }
            oas_path_param(params, name);
            i = end;
        } else {
            c.oas.text.push(pattern[i]);
            i += 1;
        }
    }
    let path_len = c.oas.text.len - path_start;
    var op: u8[>..] = [];
    oas_write_operation(c, op, params[..]);
    let op_start = c.oas.text.len;
    c.oas.text.append(op[..]);
    c.oas.ops[c.oas.op_count] = OpEntry { verb: verb, path_start: path_start, path_len: path_len,
        op_start: op_start, op_len: op.len };
    c.oas.op_count += 1;
    oas_reset_pending(c);
}

// --- output --------------------------------------------------------------------------

// Index of the first operation with the same path as operation i (so i is emitted once).
fn oas_first_of_path(c: Ctx&, i: i64) -> i64 {
    let target = c.oas.ops[i];
    let wanted = c.oas.text[target.path_start..target.path_start + target.path_len];
    for j in c.oas.op_count {
        let entry = c.oas.ops[j];
        if entry.path_len == target.path_len &&
           c.oas.text[entry.path_start..entry.path_start + entry.path_len] == wanted { return j; }
    }
    return i;
}

// The OpenAPI 3.1 document. Operations sharing a path are grouped under one path item.
fn oas_write_json(c: Ctx&, out: u8[>..]&) {
    out.append("{\"openapi\":\"3.1.0\",\"info\":{\"title\":");
    json::format_string(out, c.oas.config.title[..]);
    out.append(",\"version\":");
    json::format_string(out, c.oas.config.version[..]);
    if c.oas.config.description.len > 0 {
        out.append(",\"description\":");
        json::format_string(out, c.oas.config.description[..]);
    }
    out.append("},\"paths\":{");
    var first_path = true;
    for i in c.oas.op_count {
        if oas_first_of_path(c, i) != i { continue; }
        let entry = c.oas.ops[i];
        if !first_path { out.push(','); }
        first_path = false;
        json::format_key(out, c.oas.text[entry.path_start..entry.path_start + entry.path_len]);
        out.push('{');
        var first_op = true;
        for j in c.oas.op_count {
            let other = c.oas.ops[j];
            if other.path_len != entry.path_len ||
               c.oas.text[other.path_start..other.path_start + other.path_len] != c.oas.text[entry.path_start..entry.path_start + entry.path_len] { continue; }
            if !first_op { out.push(','); }
            first_op = false;
            json::format_key(out, other.verb[..]);
            out.append(c.oas.text[other.op_start..other.op_start + other.op_len]);
        }
        out.push('}');
    }
    out.append("}}");
}

// The docs page: Swagger UI from a pinned CDN build, pointed at the JSON document.
fn oas_write_docs(c: Ctx&, out: u8[>..]&) {
    out.append(OAS_DOCS_PAGE_START);
    json::format_string(out, c.oas.config.json_path[..]);
    out.append(OAS_DOCS_PAGE_END);
}

// Writes the document or the page as the response, for the describe pass.
fn oas_respond(c: Ctx&, kind: i32) {
    var out: u8[>..] = [];
    if kind == 1 {
        oas_write_json(c, out);
        json_raw(c, out[..]);
    } else {
        oas_write_docs(c, out);
        html(c, out[..]);
    }
}

// The entry point: web::openapi(c, info) { c.routes() { ... } }. The block is the routes;
// routes() answers the document paths itself, from its describe pass.
fn openapi<Next>(c: Ctx&, info: OpenApiInfo) {
    oas_enable(c, info);
    Next();
}
