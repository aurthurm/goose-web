import std;
import src.constants.http;
import src.constants.limits;
import src.http.headers;
namespace web;

// Route strings are owned. Matches borrow table/request memory until either changes.
// host is empty for a route declared outside c.host(); otherwise a host scope pattern.
struct Route { method: u8[..MAX_METHOD_BYTES], pattern: u8[..MAX_ROUTE_PATTERN_BYTES], host: u8[..MAX_HOST_PATTERN_BYTES], handler_id: i32 }
struct Router { routes: Route[MAX_ROUTES], count: i64 }
struct PathParam { name: const u8[:], value: const u8[:] }
struct RouteMatch {
    status: i32, handler_id: i32, params: PathParam[MAX_PATH_PARAMS], param_count: i64,
    allow: u8[..MAX_ALLOW_BYTES]
}
struct QueryValue { status: i32, value: u8[..MAX_QUERY_FIELD_BYTES] }

// Internal marker for any(). add_route accepts it as a token; it is never a
// wire method name that Allow would report, because any() suppresses 405.
const METHOD_ANY = "*";

// Segment kinds. A static segment is literal, :name is one nonempty segment, and a final
// *name takes the rest of the path (nonempty). Lower kinds are more specific.
const SEGMENT_STATIC = 0;
const SEGMENT_PARAM = 1;
const SEGMENT_WILDCARD = 2;

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
fn route_segment_kind(segment: const u8[:]) -> i32 {
    if segment.len > 0 && segment[0] == ':' { return SEGMENT_PARAM; }
    if segment.len > 0 && segment[0] == '*' { return SEGMENT_WILDCARD; }
    return SEGMENT_STATIC;
}
fn route_name(name: const u8[:]) -> bool {
    if name.len == 0 { return false; }
    for c in name {
        if !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
             (c >= '0' && c <= '9') || c == '_') { return false; }
    }
    return true;
}
// Exact slashes/case. :name consumes one nonempty segment; *name, only as the final
// segment, consumes the nonempty rest of the path. No decoding.
fn route_pattern_valid(pattern: const u8[:]) -> bool {
    if pattern.len == 0 || pattern.len > MAX_ROUTE_PATTERN_BYTES || pattern[0] != '/' { return false; }
    for c in pattern { if c <= 32 || c == 127 || c == '?' || c == '#' { return false; } }
    var pos: i64 = 1;
    var names: const u8[:][MAX_PATH_PARAMS] = [""; MAX_PATH_PARAMS];
    var count: i64 = 0;
    while pos < pattern.len {
        let end = route_segment_end(pattern, pos);
        let segment = pattern[pos..end];
        let kind = route_segment_kind(segment);
        if kind != SEGMENT_STATIC {
            let name = segment[1..];
            if !route_name(name) || count == MAX_PATH_PARAMS { return false; }
            if kind == SEGMENT_WILDCARD && end != pattern.len { return false; }
            for i in count { if names[i] == name { return false; } }
            names[count] = name;
            count += 1;
        }
        pos = end + 1;
    }
    return true;
}
// Compare segment kinds up to the shorter pattern: static beats :param, which beats *wildcard.
// 0 means the same shape.
fn route_specificity(a: const u8[:], b: const u8[:]) -> i32 {
    var ap: i64 = 1;
    var bp: i64 = 1;
    while ap < a.len && bp < b.len {
        let ae = route_segment_end(a, ap);
        let be = route_segment_end(b, bp);
        let ak = route_segment_kind(a[ap..ae]);
        let bk = route_segment_kind(b[bp..be]);
        if ak != bk { return if ak < bk { 1 } else { -1 }; }
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
        let kind = route_segment_kind(ps);
        // The wildcard is the final segment, so it takes everything after this slash.
        if kind == SEGMENT_WILDCARD { return vp < path.len; }
        if kind == SEGMENT_PARAM {
            if vs.len == 0 { return false; }
        } else { if ps != vs { return false; } }
        if pe == pattern.len || ve == path.len { return pe == pattern.len && ve == path.len; }
        pp = pe + 1;
        vp = ve + 1;
    }
}
// Host scope rank for one route against a Host header (port stripped, ASCII case-insensitive):
// -1 no match, 0 unscoped (matches any host), 1 "*.example.com" (exactly one label), 2 exact.
fn host_name(host_header: const u8[:]) -> const u8[:] {
    if host_header.len > 0 && host_header[0] == '[' {
        let end = find(host_header, "]");
        return if end < 0 { host_header } else { host_header[..end + 1] };
    }
    let colon = find(host_header, ":");
    return if colon < 0 { host_header } else { host_header[..colon] };
}
fn route_host_rank(route_host: const u8[:], host_header: const u8[:]) -> i64 {
    if route_host.len == 0 { return 0; }
    let name = host_name(host_header);
    if name.len == 0 { return -1; }
    if route_host[0] == '*' {
        let suffix = route_host[1..];
        if name.len <= suffix.len { return -1; }
        let split = name.len - suffix.len;
        if !equal_header(name[split..], suffix) || find(name[..split], ".") >= 0 { return -1; }
        return 1;
    }
    return if equal_header(route_host, name) { 2 } else { -1 };
}
// Host scope pattern: labels of letters, digits and '-', optionally with a leading "*." label.
fn route_host_valid(host: const u8[:]) -> bool {
    if host.len == 0 || host.len > MAX_HOST_PATTERN_BYTES { return false; }
    var rest = host;
    if host.len > 2 && host[0] == '*' && host[1] == '.' { rest = host[2..]; }
    var label: i64 = 0;
    for c in rest {
        if c == '.' {
            if label == 0 { return false; }
            label = 0;
        } else {
            if !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-') { return false; }
            label += 1;
        }
    }
    return label > 0;
}
// Reject same-method equivalent shapes within one host scope; IDs are application-owned
// stable integers. Scopes that differ may reuse a shape.
fn add_route_host(table: Router&, host: const u8[:], method: const u8[:], pattern: const u8[:], handler_id: i32) -> bool {
    if table.count == MAX_ROUTES || method.len == 0 || method.len > MAX_METHOD_BYTES || !route_pattern_valid(pattern) { return false; }
    if host.len > 0 && !route_host_valid(host) { return false; }
    for c in method {
        if !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
             (c >= '0' && c <= '9') || find("!#$%&'*+-.^_`|~", [c]) >= 0) { return false; }
    }
    for i in table.count {
        let r = table.routes[i];
        if r.method == method && equal_header(r.host[..], host) &&
           route_path_matches(r.pattern, pattern) && route_specificity(r.pattern, pattern) == 0 { return false; }
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
    r.host.append(host);
    r.handler_id = handler_id;
    table.routes[table.count] = r;
    table.count += 1;
    return true;
}
fn add_route(table: Router&, method: const u8[:], pattern: const u8[:], handler_id: i32) -> bool {
    return add_route_host(table, "", method, pattern, handler_id);
}
fn route_allow(result: RouteMatch&, method: const u8[:]) {
    if result.allow.len > 0 { result.allow.append(", "); }
    result.allow.append(method);
}
// Candidates that share the best path shape. The host scope must match the request.
fn route_in_class(table: Router&, i: i64, path: const u8[:], shape: const u8[:], host_header: const u8[:]) -> bool {
    return route_path_matches(table.routes[i].pattern, path) &&
        route_specificity(table.routes[i].pattern, shape) == 0 &&
        route_host_rank(table.routes[i].host[..], host_header) >= 0;
}
// Highest host-scope rank among class members with this method, or -1.
fn route_pick(table: Router&, wanted: const u8[:], path: const u8[:], shape: const u8[:], host_header: const u8[:]) -> i64 {
    var pick: i64 = -1;
    var pick_rank: i64 = -1;
    for i in table.count {
        if table.routes[i].method != wanted || !route_in_class(table, i, path, shape, host_header) { continue; }
        let rank = route_host_rank(table.routes[i].host[..], host_header);
        if rank > pick_rank {
            pick = i;
            pick_rank = rank;
        }
    }
    return pick;
}
// True when no earlier class member has the same method, so Allow lists each method once.
fn route_first_of_method(table: Router&, i: i64, path: const u8[:], shape: const u8[:], host_header: const u8[:]) -> bool {
    for j in i {
        if table.routes[j].method[..] == table.routes[i].method[..] && route_in_class(table, j, path, shape, host_header) { return false; }
    }
    return true;
}
// First choose the most specific path, then the host scope (exact, wildcard, unscoped), then the
// method. No method-based fallthrough. Allow lists registered methods in registration order,
// adding HEAD after GET. HEAD falls back to GET, then any().
fn match_route_host(table: Router&, method: const u8[:], target: const u8[:], host_header: const u8[:]) -> RouteMatch {
    var result = default<RouteMatch>();
    result.status = HTTP_NOT_FOUND;
    let path = target_path(target);
    var best: i64 = -1;
    var best_rank: i64 = -1;
    for i in table.count {
        let rank = route_host_rank(table.routes[i].host[..], host_header);
        if rank < 0 || !route_path_matches(table.routes[i].pattern, path) { continue; }
        if best < 0 {
            best = i;
            best_rank = rank;
        } else {
            let spec = route_specificity(table.routes[i].pattern, table.routes[best].pattern);
            if spec > 0 || (spec == 0 && rank > best_rank) {
                best = i;
                best_rank = rank;
            }
        }
    }
    if best < 0 { return result; }
    let shape = table.routes[best].pattern[..];
    result.status = HTTP_METHOD_NOT_ALLOWED;
    var has_head = false;
    for i in table.count {
        if route_in_class(table, i, path, shape, host_header) && table.routes[i].method == METHOD_HEAD { has_head = true; }
    }
    for i in table.count {
        if !route_in_class(table, i, path, shape, host_header) { continue; }
        let m = table.routes[i].method;
        if m == METHOD_ANY || !route_first_of_method(table, i, path, shape, host_header) { continue; }
        route_allow(result, m);
        if m == METHOD_GET && !has_head { route_allow(result, METHOD_HEAD); }
    }
    var selected = route_pick(table, method, path, shape, host_header);
    if selected < 0 && method == METHOD_HEAD { selected = route_pick(table, METHOD_GET, path, shape, host_header); }
    if selected < 0 { selected = route_pick(table, METHOD_ANY, path, shape, host_header); }
    if selected < 0 { return result; }
    result.status = HTTP_OK;
    result.handler_id = table.routes[selected].handler_id;
    route_bind(result, table.routes[selected].pattern[..], path);
    return result;
}
// Unscoped matching: a request without a Host header matches only unscoped routes.
fn match_route(table: Router&, method: const u8[:], target: const u8[:]) -> RouteMatch {
    return match_route_host(table, method, target, "");
}
// Binds :name segments and the *name rest-of-path into the result.
fn route_bind(result: RouteMatch&, pattern: const u8[:], path: const u8[:]) {
    var pp: i64 = 1;
    var vp: i64 = 1;
    while pp < pattern.len {
        let pe = route_segment_end(pattern, pp);
        let kind = route_segment_kind(pattern[pp..pe]);
        if kind == SEGMENT_WILDCARD {
            result.params[result.param_count] = PathParam { name: pattern[pp + 1..pe], value: path[vp..] };
            result.param_count += 1;
            return;
        }
        let ve = route_segment_end(path, vp);
        if kind == SEGMENT_PARAM {
            result.params[result.param_count] = PathParam { name: pattern[pp + 1..pe], value: path[vp..ve] };
            result.param_count += 1;
        }
        pp = pe + 1;
        vp = ve + 1;
    }
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
