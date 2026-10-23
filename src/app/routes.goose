import src.constants.http;
import src.constants.limits;
import src.http.headers;
import src.http.errors;
import src.routing.router;
import src.app.context;
import std;
namespace web;

// Internal marker for any(). add_route accepts it as a token; it is never a
// wire method name that Allow would report, because any() suppresses 405.
const METHOD_ANY = "*";

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
    if c.pass == PASS_MATCH {
        let full = route_full_pattern(c, pattern);
        if !add_route(c.table, method, full[..], c.route_index as i32) {
            abort(str("route rejected (duplicate, invalid method, or table full): ", method, " ", full[..]));
        }
    } else if c.matched.status == HTTP_OK && c.route_index == c.matched.handler_id {
        F();
    }
    c.route_index += 1;
}

// Same route/shape selection as match_route, plus any(). Explicit method beats
// HEAD-as-GET, which beats any(). any() never produces 405 on its path shape.
// Routes with the same shape but different static segments are filtered by
// route_path_matches inside route_in_class.
fn route_in_class(table: Router&, i: i64, path: const u8[:], shape: const u8[:]) -> bool {
    return route_path_matches(table.routes[i].pattern, path) &&
        route_specificity(table.routes[i].pattern, shape) == 0;
}

fn route_bind_params(result: RouteMatch&, pattern: const u8[:], path: const u8[:]) {
    var pp: i64 = 1;
    var vp: i64 = 1;
    while pp < pattern.len {
        let pe = route_segment_end(pattern, pp);
        let ve = route_segment_end(path, vp);
        if pe > pp && pattern[pp] == ':' {
            result.params[result.param_count] = PathParam { name: pattern[pp + 1..pe], value: path[vp..ve] };
            result.param_count += 1;
        }
        pp = pe + 1;
        vp = ve + 1;
    }
}

fn route_select(table: Router&, method: const u8[:], path: const u8[:]) -> RouteMatch {
    var result = default<RouteMatch>();
    result.status = HTTP_NOT_FOUND;
    var best: i64 = -1;
    for i in table.count {
        if route_path_matches(table.routes[i].pattern, path) &&
           (best < 0 || route_specificity(table.routes[i].pattern, table.routes[best].pattern) > 0) { best = i; }
    }
    if best < 0 { return result; }
    let shape = table.routes[best].pattern[..];
    var has_head = false;
    for i in table.count {
        if route_in_class(table, i, path, shape) && table.routes[i].method == METHOD_HEAD { has_head = true; }
    }
    result.status = HTTP_METHOD_NOT_ALLOWED;
    var selected: i64 = -1;
    var fallback: i64 = -1;
    var any_route: i64 = -1;
    for i in table.count {
        if !route_in_class(table, i, path, shape) { continue; }
        let m = table.routes[i].method;
        if m == METHOD_ANY { any_route = i; continue; }
        route_allow(result, m);
        if m == METHOD_GET {
            fallback = i;
            if !has_head { route_allow(result, METHOD_HEAD); }
        }
        if m == method { selected = i; }
    }
    if selected < 0 && method == METHOD_HEAD { selected = fallback; }
    if selected < 0 { selected = any_route; }
    if selected < 0 { return result; }
    result.status = HTTP_OK;
    result.handler_id = table.routes[selected].handler_id;
    route_bind_params(result, table.routes[selected].pattern[..], path);
    return result;
}

// The block runs twice: a match pass that only records routes, then (for a matched
// request) a dispatch pass where only the selected route's body runs. Keep the block
// declarative: route calls, c.group, and calls to functions that declare routes.
// A `return` inside a route body leaves routes() before its cleanup, so every entry
// resets the routing state it depends on.
fn routes<F>(c: Ctx&) {
    c.table = router();
    c.prefix_count = 0;
    c.route_index = 0;
    c.pass = PASS_MATCH;
    F();
    c.matched = route_select(c.table, c.request.method, path(c));
    c.pass = PASS_DISPATCH;
    c.route_index = 0;
    c.prefix_count = 0;
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

fn get<F>(c: Ctx&, pattern: const u8[:]) { route_add(c, METHOD_GET, pattern, F); }
fn post<F>(c: Ctx&, pattern: const u8[:]) { route_add(c, METHOD_POST, pattern, F); }
fn put<F>(c: Ctx&, pattern: const u8[:]) { route_add(c, METHOD_PUT, pattern, F); }
fn patch<F>(c: Ctx&, pattern: const u8[:]) { route_add(c, METHOD_PATCH, pattern, F); }
fn delete<F>(c: Ctx&, pattern: const u8[:]) { route_add(c, METHOD_DELETE, pattern, F); }
fn head<F>(c: Ctx&, pattern: const u8[:]) { route_add(c, METHOD_HEAD, pattern, F); }
fn options<F>(c: Ctx&, pattern: const u8[:]) { route_add(c, METHOD_OPTIONS, pattern, F); }
fn any<F>(c: Ctx&, pattern: const u8[:]) { route_add(c, METHOD_ANY, pattern, F); }
