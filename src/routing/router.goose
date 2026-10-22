import std;
import src.constants.http;
import src.constants.limits;
namespace web;

// Route strings are owned. Matches borrow table/request memory until either changes.
struct Route { method: u8[..MAX_METHOD_BYTES], pattern: u8[..MAX_ROUTE_PATTERN_BYTES], handler_id: i32 }
struct Router { routes: Route[MAX_ROUTES], count: i64 }
struct PathParam { name: const u8[:], value: const u8[:] }
struct RouteMatch {
    status: i32, handler_id: i32, params: PathParam[MAX_PATH_PARAMS], param_count: i64,
    allow: u8[..MAX_ALLOW_BYTES]
}
struct QueryValue { status: i32, value: u8[..MAX_QUERY_FIELD_BYTES] }

fn router() -> Router { return default<Router>(); }
fn target_path(target: const u8[:]) -> const u8[:] {
    let q = find(target, "?");
    return if q < 0 { target } else { target[..q] };
}
fn target_query(target: const u8[:]) -> const u8[:] {
    let q = find(target, "?");
    return if q < 0 { target[..0] } else { target[q + 1..] };
}
fn route_segment_end(path: const u8[:], start: i64) -> i64 {
    var end = start;
    while end < path.len && path[end] != '/' { end += 1; }
    return end;
}
fn route_name(name: const u8[:]) -> bool {
    if name.len == 0 { return false; }
    for c in name {
        if !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
             (c >= '0' && c <= '9') || c == '_') { return false; }
    }
    return true;
}
// Exact slashes/case; :name consumes one nonempty segment. No wildcard or decoding.
fn route_pattern_valid(pattern: const u8[:]) -> bool {
    if pattern.len == 0 || pattern.len > MAX_ROUTE_PATTERN_BYTES || pattern[0] != '/' { return false; }
    for c in pattern { if c <= 32 || c == 127 || c == '?' || c == '#' { return false; } }
    var pos: i64 = 1;
    var names: const u8[:][MAX_PATH_PARAMS] = [""; MAX_PATH_PARAMS];
    var count: i64 = 0;
    while pos < pattern.len {
        let end = route_segment_end(pattern, pos);
        let segment = pattern[pos..end];
        if segment.len > 0 && segment[0] == ':' {
            let name = segment[1..];
            if !route_name(name) || count == MAX_PATH_PARAMS { return false; }
            for i in count { if names[i] == name { return false; } }
            names[count] = name;
            count += 1;
        }
        pos = end + 1;
    }
    return true;
}
// Compare static/parameter positions; earlier static segments have priority.
fn route_specificity(a: const u8[:], b: const u8[:]) -> i32 {
    var ap: i64 = 1;
    var bp: i64 = 1;
    while ap < a.len && bp < b.len {
        let ae = route_segment_end(a, ap);
        let be = route_segment_end(b, bp);
        let av = a[ap..ae];
        let bv = b[bp..be];
        let aparam = av.len > 0 && av[0] == ':';
        let bparam = bv.len > 0 && bv[0] == ':';
        if aparam != bparam { return if aparam { -1 } else { 1 }; }
        ap = ae + 1;
        bp = be + 1;
    }
    return 0;
}
fn route_path_matches(pattern: const u8[:], path: const u8[:]) -> bool {
    if path.len == 0 || path[0] != '/' { return false; }
    var pp: i64 = 1;
    var vp: i64 = 1;
    loop {
        let pe = route_segment_end(pattern, pp);
        let ve = route_segment_end(path, vp);
        let ps = pattern[pp..pe];
        let vs = path[vp..ve];
        if ps.len > 0 && ps[0] == ':' {
            if vs.len == 0 { return false; }
        } else { if ps != vs { return false; } }
        if pe == pattern.len || ve == path.len { return pe == pattern.len && ve == path.len; }
        pp = pe + 1;
        vp = ve + 1;
    }
}
// Reject same-method equivalent shapes; IDs are application-owned stable integers.
fn add_route(table: Router&, method: const u8[:], pattern: const u8[:], handler_id: i32) -> bool {
    if table.count == MAX_ROUTES || method.len == 0 || method.len > MAX_METHOD_BYTES || !route_pattern_valid(pattern) { return false; }
    for c in method {
        if !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
             (c >= '0' && c <= '9') || find("!#$%&'*+-.^_`|~", [c]) >= 0) { return false; }
    }
    for i in table.count {
        let r = table.routes[i];
        if r.method == method && route_path_matches(r.pattern, pattern) && route_specificity(r.pattern, pattern) == 0 { return false; }
    }
    // Bound the union of registered methods, reserving implicit HEAD. This keeps
    // every Allow value within the response-header limit without truncation.
    var budget: i64 = method.len + 2 + METHOD_HEAD.len + 2;
    var already = false;
    for i in table.count {
        let m = table.routes[i].method;
        if m == method { already = true; }
        var first = true;
        for j in i { if table.routes[j].method == m { first = false; } }
        if first { budget += m.len + 2; }
    }
    if already { budget -= method.len + 2; }
    if budget > MAX_ALLOW_BYTES { return false; }
    var r = default<Route>();
    r.method.append(method);
    r.pattern.append(pattern);
    r.handler_id = handler_id;
    table.routes[table.count] = r;
    table.count += 1;
    return true;
}
fn route_allow(result: RouteMatch&, method: const u8[:]) {
    if result.allow.len > 0 { result.allow.append(", "); }
    result.allow.append(method);
}
// First choose the most specific path, then the method. No method-based fallthrough.
// Allow lists registered methods in registration order, adding HEAD after GET.
fn match_route(table: Router&, method: const u8[:], target: const u8[:]) -> RouteMatch {
    var result = default<RouteMatch>();
    result.status = HTTP_NOT_FOUND;
    let path = target_path(target);
    var best: i64 = -1;
    for i in table.count {
        if route_path_matches(table.routes[i].pattern, path) &&
           (best < 0 || route_specificity(table.routes[i].pattern, table.routes[best].pattern) > 0) { best = i; }
    }
    if best < 0 { return result; }
    result.status = HTTP_METHOD_NOT_ALLOWED;
    var selected: i64 = -1;
    var fallback: i64 = -1;
    var has_head = false;
    for i in table.count {
        let r = table.routes[i];
        if route_path_matches(r.pattern, path) && route_specificity(r.pattern, table.routes[best].pattern) == 0 {
            if r.method == METHOD_HEAD { has_head = true; }
        }
    }
    for i in table.count {
        let r = table.routes[i];
        if route_path_matches(r.pattern, path) && route_specificity(r.pattern, table.routes[best].pattern) == 0 {
            route_allow(result, r.method);
            if r.method == METHOD_GET {
                fallback = i;
                if !has_head { route_allow(result, METHOD_HEAD); }
            }
            if r.method == method { selected = i; }
        }
    }
    if selected < 0 && method == METHOD_HEAD { selected = fallback; }
    if selected < 0 { return result; }
    result.status = HTTP_OK;
    result.handler_id = table.routes[selected].handler_id;
    let pattern = table.routes[selected].pattern[..];
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
    return result;
}
fn path_param(result: RouteMatch&, name: const u8[:]) -> const u8[:] {
    for i in result.param_count { if result.params[i].name == name { return result.params[i].value; } }
    return "";
}
fn query_hex(c: u8) -> i32 {
    if c >= '0' && c <= '9' { return c - '0'; }
    if c >= 'a' && c <= 'f' { return c - 'a' + 10; }
    if c >= 'A' && c <= 'F' { return c - 'A' + 10; }
    return -1;
}
// Decoded bytes are binary-safe; + means space. No UTF-8 normalization is applied.
fn query_decode(raw: const u8[:]) -> QueryValue {
    var result = default<QueryValue>();
    result.status = HTTP_OK;
    var pos: i64 = 0;
    while pos < raw.len {
        var c = raw[pos];
        if c == '%' {
            if pos + 2 >= raw.len { result.status = HTTP_BAD_REQUEST; return result; }
            let hi = query_hex(raw[pos + 1]);
            let lo = query_hex(raw[pos + 2]);
            if hi < 0 || lo < 0 { result.status = HTTP_BAD_REQUEST; return result; }
            c = (hi * 16 + lo) as u8;
            pos += 2;
        } else { if c == '+' { c = ' '; } }
        if result.value.len == MAX_QUERY_FIELD_BYTES { result.status = HTTP_CONTENT_TOO_LARGE; return result; }
        result.value.push(c);
        pos += 1;
    }
    return result;
}
// First occurrence wins (including empty values). Validate the entire query, even
// after finding a key. QUERY_MISSING, HTTP_OK, HTTP_BAD_REQUEST, or
// HTTP_CONTENT_TOO_LARGE explicitly report missing, found, bad escapes, or overflow.
fn query_value(target: const u8[:], key: const u8[:]) -> QueryValue {
    var result = default<QueryValue>();
    result.status = QUERY_MISSING;
    let query = target_query(target);
    var pos: i64 = 0;
    while pos < query.len {
        let amp = find(query[pos..], "&");
        let end = if amp < 0 { query.len } else { pos + amp };
        let pair = query[pos..end];
        let equals = find(pair, "=");
        let name_raw = if equals < 0 { pair } else { pair[..equals] };
        let value_raw = if equals < 0 { pair[pair.len..] } else { pair[equals + 1..] };
        let name = query_decode(name_raw);
        let value = query_decode(value_raw);
        if name.status != HTTP_OK { return name; }
        if value.status != HTTP_OK { return value; }
        if result.status == QUERY_MISSING && name.value == key { result = value; }
        pos = end + 1;
    }
    return result;
}
