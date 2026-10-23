import src.constants.http;
import src.constants.limits;
import src.http.headers;
import src.http.errors;
import src.routing.router;
import src.app.context;
import src.app.openapi;
import std;
namespace web;

// Joins group prefixes with the route pattern. A prefix ending in "/" is trimmed so
// "/api/" plus "/x" does not become "//x"; the route "/" names the group itself.
// Aborts on overflow or an invalid joined pattern, since both are programmer errors.
fn route_full_pattern(c: Ctx&, pattern: const u8[:]) -> u8[..MAX_ROUTE_PATTERN_BYTES] {
    var full: u8[..MAX_ROUTE_PATTERN_BYTES] = [];
    for i in c.prefix_count {
        var base = c.prefixes[i];
        if base.len > 0 && base[base.len - 1] == '/' { base = base[..base.len - 1]; }
        if base.len > MAX_ROUTE_PATTERN_BYTES - full.len { abort("route pattern too long"); }
        full.append(base);
    }
    if pattern == "/" {
        if full.len == 0 { full.append("/"); }
    } else {
        if pattern.len > MAX_ROUTE_PATTERN_BYTES - full.len { abort("route pattern too long"); }
        full.append(pattern);
    }
    if !route_pattern_valid(full[..]) { abort(str("invalid route pattern: ", full[..])); }
    return full;
}

// Match pass records the route in the table; dispatch pass runs F only when this
// declaration is the one selected. Route IDs are declaration order within the block.
fn route_add<F>(c: Ctx&, method: const u8[:], pattern: const u8[:]) {
    if c.pass == PASS_IDLE { abort("route declared outside c.routes()"); }
    if c.pass == PASS_DESCRIBE {
        // Match-all routes (any) have no OpenAPI method, so they are not documented.
        let full = route_full_pattern(c, pattern);
        if method != METHOD_ANY { oas_add_operation(c, method, full[..]); } else { oas_reset_pending(c); }
    } else if c.pass == PASS_MATCH {
        let full = route_full_pattern(c, pattern);
        if !add_route_host(c.table, c.host_scope, method, full[..], c.route_index as i32) {
            abort(str("route rejected (duplicate, invalid method, or table full): ", method, " ", full[..]));
        }
    } else if c.matched.status == HTTP_OK && c.route_index == c.matched.handler_id {
        F();
    }
    c.route_index += 1;
}

// Describe pass: runs the block only to collect operations (no route body runs), then
// answers the document request. Annotations before a route attach to that route.
fn describe_routes<F>(c: Ctx&, kind: i32) {
    oas_begin(c);
    c.pass = PASS_DESCRIBE;
    c.route_index = 0;
    c.prefix_count = 0;
    F();
    c.prefix_count = 0;
    c.pass = PASS_IDLE;
    oas_respond(c, kind);
}

// The block runs twice: a match pass that only records routes, then (for a matched
// request) a dispatch pass where only the selected route's body runs. Keep the block
// declarative: route calls, c.group, and calls to functions that declare routes.
// A `return` inside a route body leaves routes() before its cleanup, so every entry
// resets the routing state it depends on.
fn routes<F>(c: Ctx&) {
    let kind = oas_kind(c);
    if kind != 0 {
        describe_routes(c, kind, F);
        return;
    }
    c.table = router();
    c.prefix_count = 0;
    c.host_scope = "";
    c.route_index = 0;
    c.pass = PASS_MATCH;
    F();
    c.matched = match_route_host(c.table, c.request.method, c.request.target, header(c, HEADER_HOST));
    c.pass = PASS_DISPATCH;
    c.route_index = 0;
    c.prefix_count = 0;
    c.host_scope = "";
    if c.matched.status == HTTP_OK {
        F();
    } else if c.matched.status == HTTP_METHOD_NOT_ALLOWED {
        // Allow is registration-ordered and bounded by MAX_ALLOW_BYTES at registration.
        assert(set_header(c.response, HEADER_ALLOW, c.matched.allow[..]));
        fail(c, HTTP_METHOD_NOT_ALLOWED, "method_not_allowed", "Method not allowed for this route");
    } else {
        fail(c, HTTP_NOT_FOUND, "not_found", "Route not found");
    }
    c.pass = PASS_IDLE;
}

// Nested prefixes are pushed for the duration of F in both passes.
fn group<F>(c: Ctx&, prefix: const u8[:]) {
    if c.pass == PASS_IDLE { abort("c.group must be called inside c.routes()"); }
    if c.prefix_count == MAX_GROUP_DEPTH { abort("route groups nested too deeply"); }
    c.prefixes[c.prefix_count] = prefix;
    c.prefix_count += 1;
    F();
    c.prefix_count -= 1;
}

// Host scope: routes declared in F match only when the Host header (port stripped,
// case-insensitive) equals pattern, or for "*.example.com" when exactly one label precedes
// the rest. Scopes do not nest. Matching prefers the path shape first; the host scope only
// breaks ties, so a scoped route still answers 405 for its own path when the method differs.
fn host<F>(c: Ctx&, pattern: const u8[:]) {
    if c.pass == PASS_IDLE { abort("c.host must be called inside c.routes()"); }
    if c.host_scope.len > 0 { abort("c.host scopes cannot be nested"); }
    if !route_host_valid(pattern) { abort(str("invalid host pattern: ", pattern)); }
    c.host_scope = pattern;
    F();
    c.host_scope = "";
}

fn get<F>(c: Ctx&, pattern: const u8[:]) { route_add(c, METHOD_GET, pattern, F); }
fn post<F>(c: Ctx&, pattern: const u8[:]) { route_add(c, METHOD_POST, pattern, F); }
fn put<F>(c: Ctx&, pattern: const u8[:]) { route_add(c, METHOD_PUT, pattern, F); }
fn patch<F>(c: Ctx&, pattern: const u8[:]) { route_add(c, METHOD_PATCH, pattern, F); }
fn delete<F>(c: Ctx&, pattern: const u8[:]) { route_add(c, METHOD_DELETE, pattern, F); }
fn head<F>(c: Ctx&, pattern: const u8[:]) { route_add(c, METHOD_HEAD, pattern, F); }
fn options<F>(c: Ctx&, pattern: const u8[:]) { route_add(c, METHOD_OPTIONS, pattern, F); }
fn any<F>(c: Ctx&, pattern: const u8[:]) { route_add(c, METHOD_ANY, pattern, F); }
