// Field rules and validation for typed bodies, queries, forms and settings (docs/api.md,
// "Validation"). A struct declares its rules once, in a generic-free overload:
//
//     fn web::rules(v: NewNote&, r: web::Rules&) {
//         r.field("title").required().min_len(1).max_len(200);
//         r.field("priority").ge(0).le(5);
//         r.field("slug").pattern(web::PATTERN_SLUG);
//     }
//
// The rules table is fixed (RULES_MAX entries) and builders only record what they are told, so
// nothing grows at request time. Limits count code points for text. Bounds are whole numbers;
// float fields compare against them. Text with an empty value skips pattern and format checks
// (min_len(1) or required() reject it). check_rules<T>() validates the table at startup:
// unknown names, duplicates, min above max, and max_len above the field's capacity.
//
// validate_present<T>(value, root, present, failed, out) walks fields<T>: a missing required
// field is "missing"; a present field gets the check_value overload for its type; a field the
// decoder already rejected is skipped. Then validate_model (if no issue so far) runs for
// cross-field checks. normalize runs before validation. Both hooks default to no-ops.
//
// Nested structs need one registration, as for the codec: `fn web::check_value(v: Inner&,
// rule: web::FieldRule&, path: const u8[:], out: web::Issues&) { web::validate_nested(v, path, out); }`.
import src.constants.http;
import src.json.codec;
import src.json.issues;
import src.app.context;
import std;
namespace web;

const RULES_MAX = 32;
// Longest text a capacity probe (check_rules) builds. Larger max_len values skip that probe.
const RULE_PROBE_MAX = 4096;

// Builtin patterns, matched without a regex engine. Each has a regex spelling for OpenAPI.
const PATTERN_NONE = 0;
const PATTERN_SLUG = 1;
const PATTERN_UUID = 2;
const PATTERN_ASCII_ALNUM = 3;
const PATTERN_DIGITS = 4;
const PATTERN_HEX = 5;

// Builtin formats: a pragmatic RFC 5322 subset for email, and http/https URLs.
const FORMAT_NONE = 0;
const FORMAT_EMAIL = 1;
const FORMAT_URI = 2;

// One field's constraints. Bounds are set with has_* flags so that 0 is a real bound.
struct FieldRule {
    name: u8[..64],
    required: bool,
    lax: bool,
    secret: bool,
    has_min_len: bool, min_len: i64,
    has_max_len: bool, max_len: i64,
    has_ge: bool, ge: i64,
    has_gt: bool, gt: i64,
    has_le: bool, le: i64,
    has_lt: bool, lt: i64,
    has_multiple: bool, multiple_of: i64,
    has_min_items: bool, min_items: i64,
    has_max_items: bool, max_items: i64,
    pattern_kind: i64,
    format_kind: i64,
}

// The rules of one struct. at is the 1-based index of the rule the builders change (0: none),
// overflow is set when more than RULES_MAX fields were declared (check_rules reports it).
struct Rules { items: FieldRule[..32], at: i64, overflow: bool }

// --- builders -------------------------------------------------------------------------

// Starts (or restarts) the rule for a field. Builders after it apply to this field.
fn field(r: Rules&, name: const u8[:]) -> Rules& {
    if r.items.len == r.items.cap {
        r.overflow = true;
        r.at = 0;
        return r;
    }
    var rule = FieldRule { .. };
    issue_put(rule.name, name);
    r.items.push(rule);
    r.at = r.items.len;
    return r;
}

fn required(r: Rules&) -> Rules& {
    if r.at > 0 { r.items[r.at - 1].required = true; }
    return r;
}

fn lax(r: Rules&) -> Rules& {
    if r.at > 0 { r.items[r.at - 1].lax = true; }
    return r;
}

fn secret(r: Rules&) -> Rules& {
    if r.at > 0 { r.items[r.at - 1].secret = true; }
    return r;
}

fn min_len(r: Rules&, n: i64) -> Rules& {
    if r.at > 0 { r.items[r.at - 1].has_min_len = true; r.items[r.at - 1].min_len = n; }
    return r;
}

fn max_len(r: Rules&, n: i64) -> Rules& {
    if r.at > 0 { r.items[r.at - 1].has_max_len = true; r.items[r.at - 1].max_len = n; }
    return r;
}

fn ge(r: Rules&, n: i64) -> Rules& {
    if r.at > 0 { r.items[r.at - 1].has_ge = true; r.items[r.at - 1].ge = n; }
    return r;
}

fn gt(r: Rules&, n: i64) -> Rules& {
    if r.at > 0 { r.items[r.at - 1].has_gt = true; r.items[r.at - 1].gt = n; }
    return r;
}

fn le(r: Rules&, n: i64) -> Rules& {
    if r.at > 0 { r.items[r.at - 1].has_le = true; r.items[r.at - 1].le = n; }
    return r;
}

fn lt(r: Rules&, n: i64) -> Rules& {
    if r.at > 0 { r.items[r.at - 1].has_lt = true; r.items[r.at - 1].lt = n; }
    return r;
}

fn multiple_of(r: Rules&, n: i64) -> Rules& {
    if r.at > 0 { r.items[r.at - 1].has_multiple = true; r.items[r.at - 1].multiple_of = n; }
    return r;
}

fn min_items(r: Rules&, n: i64) -> Rules& {
    if r.at > 0 { r.items[r.at - 1].has_min_items = true; r.items[r.at - 1].min_items = n; }
    return r;
}

fn max_items(r: Rules&, n: i64) -> Rules& {
    if r.at > 0 { r.items[r.at - 1].has_max_items = true; r.items[r.at - 1].max_items = n; }
    return r;
}

fn pattern(r: Rules&, kind: i64) -> Rules& {
    if r.at > 0 { r.items[r.at - 1].pattern_kind = kind; }
    return r;
}

fn format(r: Rules&, kind: i64) -> Rules& {
    if r.at > 0 { r.items[r.at - 1].format_kind = kind; }
    return r;
}

// The hook a struct overloads. The generic default adds nothing.
fn rules<T>(v: T&, r: Rules&) { }

// Hooks: normalize runs on a decoded value before validation (trim, lowercase); validate_model
// runs after the field checks pass, for cross-field rules. Defaults do nothing.
fn normalize<T>(v: T&) { }
fn validate_model<T>(v: T&, out: Issues&) { }

// The rules of T, from its rules overload.
fn rules_for<T>(v: T&) -> Rules {
    var r = Rules { .. };
    rules(v, r);
    return r;
}

// Index of the rule for a field name, or -1.
fn rule_index(rs: Rules&, name: const u8[:]) -> i64 {
    for i in rs.items.len {
        if rs.items[i].name[..] == name { return i; }
    }
    return -1;
}

// --- builtin patterns and formats -------------------------------------------------------

fn is_lower(c: u8) -> bool { return c >= 'a' && c <= 'z'; }
fn is_upper(c: u8) -> bool { return c >= 'A' && c <= 'Z'; }
fn is_digit(c: u8) -> bool { return c >= '0' && c <= '9'; }
fn is_alnum(c: u8) -> bool { return is_lower(c) || is_upper(c) || is_digit(c); }
fn is_hex(c: u8) -> bool { return is_digit(c) || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F'); }

// The regex each builtin pattern stands for (OpenAPI "pattern", and the message).
fn pattern_regex(kind: i64) -> const u8[:] {
    if kind == PATTERN_SLUG { return "^[a-z0-9]+(?:-[a-z0-9]+)*$"; }
    if kind == PATTERN_UUID { return "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"; }
    if kind == PATTERN_ASCII_ALNUM { return "^[A-Za-z0-9]+$"; }
    if kind == PATTERN_DIGITS { return "^[0-9]+$"; }
    if kind == PATTERN_HEX { return "^[0-9a-fA-F]+$"; }
    return "";
}

// Lowercase words of [a-z0-9] joined by single hyphens.
fn slug_ok(s: const u8[:]) -> bool {
    if s.len == 0 { return false; }
    var after_dash = true;
    for c in s {
        if is_lower(c) || is_digit(c) {
            after_dash = false;
        } else if c == '-' {
            if after_dash { return false; }
            after_dash = true;
        } else {
            return false;
        }
    }
    return !after_dash;
}

fn uuid_ok(s: const u8[:]) -> bool {
    if s.len != 36 { return false; }
    for i in 36 {
        if i == 8 || i == 13 || i == 18 || i == 23 {
            if s[i] != '-' { return false; }
        } else if !is_hex(s[i]) {
            return false;
        }
    }
    return true;
}

fn all_of(s: const u8[:], kind: i64) -> bool {
    if s.len == 0 { return false; }
    for c in s {
        let ok = if kind == PATTERN_ASCII_ALNUM { is_alnum(c) } else if kind == PATTERN_DIGITS { is_digit(c) } else { is_hex(c) };
        if !ok { return false; }
    }
    return true;
}

fn pattern_matches(kind: i64, s: const u8[:]) -> bool {
    if kind == PATTERN_SLUG { return slug_ok(s); }
    if kind == PATTERN_UUID { return uuid_ok(s); }
    if kind == PATTERN_NONE { return true; }
    return all_of(s, kind);
}

// The RFC 5322 atext characters beyond letters and digits.
fn is_atext(c: u8) -> bool {
    return is_alnum(c) || c == '!' || c == '#' || c == '$' || c == '%' || c == '&' || c == '\'' || c == '*' ||
        c == '+' || c == '-' || c == '/' || c == '=' || c == '?' || c == '^' || c == '_' || c == '`' ||
        c == '{' || c == '|' || c == '}' || c == '~';
}

// A domain label: 1..63 letters, digits or hyphens, not starting or ending with a hyphen.
fn label_ok(label: const u8[:]) -> bool {
    if label.len == 0 || label.len > 63 { return false; }
    if label[0] == '-' || label[label.len - 1] == '-' { return false; }
    for c in label {
        if !is_alnum(c) && c != '-' { return false; }
    }
    return true;
}

// local@domain with a pragmatic RFC 5322 subset: dot-separated atoms locally, at least two
// labels in the domain, and an alphabetic top label of at least two letters.
fn email_ok(s: const u8[:]) -> bool {
    if s.len > 254 { return false; }
    let at = find(s, "@");
    if at <= 0 || at >= s.len - 1 { return false; }
    let local = s[..at];
    let domain = s[at + 1..];
    if local.len > 64 || find(domain, "@") >= 0 { return false; }
    var after_dot = true;
    for c in local {
        if c == '.' {
            if after_dot { return false; }
            after_dot = true;
        } else if is_atext(c) {
            after_dot = false;
        } else {
            return false;
        }
    }
    if after_dot { return false; }
    var pos: i64 = 0;
    var labels: i64 = 0;
    var top_at: i64 = 0;
    while pos <= domain.len {
        let dot = find(domain[pos..], ".");
        let end = if dot < 0 { domain.len } else { pos + dot };
        if !label_ok(domain[pos..end]) { return false; }
        labels += 1;
        top_at = pos;
        pos = end + 1;
    }
    if labels < 2 { return false; }
    let top = domain[top_at..];
    for c in top {
        if !is_lower(c) && !is_upper(c) { return false; }
    }
    return top.len >= 2;
}

// http:// or https:// followed by a host of printable characters with no spaces.
fn uri_ok(s: const u8[:]) -> bool {
    var rest = s;
    if s.len >= 8 && s[..8] == "https://" { rest = s[8..]; }
    else if s.len >= 7 && s[..7] == "http://" { rest = s[7..]; }
    else { return false; }
    if rest.len == 0 || !is_alnum(rest[0]) { return false; }
    for c in rest {
        if c <= ' ' || c == 127 { return false; }
    }
    return true;
}

fn format_matches(kind: i64, s: const u8[:]) -> bool {
    if kind == FORMAT_EMAIL { return email_ok(s); }
    if kind == FORMAT_URI { return uri_ok(s); }
    return true;
}

// --- issue helpers ---------------------------------------------------------------------

// "address.zip" for field zip in the object at path "address"; "zip" at the top.
fn join_path(scope: const u8[:], name: const u8[:]) -> u8[>..] {
    if scope.len == 0 { return str(name); }
    return str(scope, ".", name);
}

// "1 character" or "2 characters" (and "item" / "items" for lists).
fn chars_text(n: i64) -> u8[>..] {
    return str(n, if n == 1 { " character" } else { " characters" });
}

fn items_text(n: i64) -> u8[>..] {
    return str(n, if n == 1 { " item" } else { " items" });
}

// --- per-type checks -------------------------------------------------------------------

// Code points: bytes that do not continue a UTF-8 sequence.
fn code_points(s: const u8[:]) -> i64 {
    var n: i64 = 0;
    for c in s {
        if (c & 192) != 128 { n += 1; }
    }
    return n;
}

fn check_text(s: const u8[:], rule: FieldRule&, path: const u8[:], out: Issues&) {
    let n = code_points(s);
    if rule.has_min_len && n < rule.min_len {
        issue_add(out, path, "string_too_short", str("String should have at least ", chars_text(rule.min_len)));
    }
    if rule.has_max_len && n > rule.max_len {
        issue_add(out, path, "string_too_long", str("String should have at most ", chars_text(rule.max_len)));
    }
    if s.len == 0 { return; }
    if rule.pattern_kind != PATTERN_NONE && !pattern_matches(rule.pattern_kind, s) {
        issue_add(out, path, "string_pattern_mismatch", str("String should match pattern '", pattern_regex(rule.pattern_kind), "'"));
    }
    if rule.format_kind == FORMAT_EMAIL && !email_ok(s) {
        issue_add(out, path, "value_error", "value is not a valid email address");
    }
    if rule.format_kind == FORMAT_URI && !uri_ok(s) {
        issue_add(out, path, "value_error", "Input should be a valid URL, must be http or https");
    }
}

fn check_integer(x: i64, rule: FieldRule&, path: const u8[:], out: Issues&) {
    if rule.has_ge && x < rule.ge {
        issue_add(out, path, "greater_than_equal", str("Input should be greater than or equal to ", rule.ge));
    }
    if rule.has_gt && x <= rule.gt {
        issue_add(out, path, "greater_than", str("Input should be greater than ", rule.gt));
    }
    if rule.has_le && x > rule.le {
        issue_add(out, path, "less_than_equal", str("Input should be less than or equal to ", rule.le));
    }
    if rule.has_lt && x >= rule.lt {
        issue_add(out, path, "less_than", str("Input should be less than ", rule.lt));
    }
    if rule.has_multiple && x % rule.multiple_of != 0 {
        issue_add(out, path, "multiple_of", str("Input should be a multiple of ", rule.multiple_of));
    }
}

fn check_float(x: f64, rule: FieldRule&, path: const u8[:], out: Issues&) {
    if rule.has_ge && x < rule.ge {
        issue_add(out, path, "greater_than_equal", str("Input should be greater than or equal to ", rule.ge));
    }
    if rule.has_gt && x <= rule.gt {
        issue_add(out, path, "greater_than", str("Input should be greater than ", rule.gt));
    }
    if rule.has_le && x > rule.le {
        issue_add(out, path, "less_than_equal", str("Input should be less than or equal to ", rule.le));
    }
    if rule.has_lt && x >= rule.lt {
        issue_add(out, path, "less_than", str("Input should be less than ", rule.lt));
    }
    if rule.has_multiple {
        let q = x / rule.multiple_of;
        if q != (q as i64) {
            issue_add(out, path, "multiple_of", str("Input should be a multiple of ", rule.multiple_of));
        }
    }
}

// Text is a u8 slice; every other limited array is a list (concrete beats generic E[:]).
fn check_seq(s: const u8[:], rule: FieldRule&, path: const u8[:], out: Issues&) {
    check_text(s, rule, path, out);
}
fn check_seq<E>(s: E[:], rule: FieldRule&, path: const u8[:], out: Issues&) {
    let n = s.len;
    if rule.has_min_items && n < rule.min_items {
        issue_add(out, path, "too_short", str("List should have at least ", items_text(rule.min_items)));
    }
    if rule.has_max_items && n > rule.max_items {
        issue_add(out, path, "too_long", str("List should have at most ", items_text(rule.max_items)));
    }
    var none = FieldRule { .. };
    for i in s.len {
        let item_path = str(path, "[", i, "]");
        check_value(s[i], none, item_path[..], out);
    }
}

// Limited text and arrays, and any struct without a registration (which fails to compile here).
fn check_value<T>(v: T&, rule: FieldRule&, path: const u8[:], out: Issues&) {
    check_seq(v[..], rule, path, out);
}

fn check_value(v: i64&, rule: FieldRule&, path: const u8[:], out: Issues&) { check_integer(v, rule, path, out); }
fn check_value(v: i32&, rule: FieldRule&, path: const u8[:], out: Issues&) { check_integer(v, rule, path, out); }
fn check_value(v: i16&, rule: FieldRule&, path: const u8[:], out: Issues&) { check_integer(v, rule, path, out); }
fn check_value(v: i8&, rule: FieldRule&, path: const u8[:], out: Issues&) { check_integer(v, rule, path, out); }
fn check_value(v: u32&, rule: FieldRule&, path: const u8[:], out: Issues&) { check_integer(v, rule, path, out); }
fn check_value(v: u16&, rule: FieldRule&, path: const u8[:], out: Issues&) { check_integer(v, rule, path, out); }
fn check_value(v: u8&, rule: FieldRule&, path: const u8[:], out: Issues&) { check_integer(v, rule, path, out); }
// Values above i64 max are clamped: they stay above every bound an i64 rule can state.
fn check_value(v: u64&, rule: FieldRule&, path: const u8[:], out: Issues&) {
    let clamped = if v > 9223372036854775807 { 9223372036854775807 } else { v as i64 };
    check_integer(clamped, rule, path, out);
}
fn check_value(v: bool&, rule: FieldRule&, path: const u8[:], out: Issues&) { }
fn check_value(v: f64&, rule: FieldRule&, path: const u8[:], out: Issues&) { check_float(v, rule, path, out); }
fn check_value(v: f32&, rule: FieldRule&, path: const u8[:], out: Issues&) { check_float(v, rule, path, out); }

// Validates the fields of a struct. present and failed are bit masks in declaration order.
fn validate_fields<T>(v: T&, rs: Rules&, present: u64, failed: u64, scope: const u8[:], out: Issues&) {
    var bit: u64 = 1;
    const for <N, A> in fields<T> {
        if !json_skip(v, N) {
            let path = join_path(scope, N);
            var rule = FieldRule { .. };
            let at = rule_index(rs, N);
            if at >= 0 { rule = rs.items[at]; }
            if (failed & bit) != 0 {
                // The decoder already reported this field.
            } else if (present & bit) == 0 {
                if rule.required { issue_add(out, path[..], "missing", "Field required"); }
            } else {
                check_value(v.A, rule, path[..], out);
            }
        }
        bit <<= 1;
    }
}

// Validates a nested struct at path (the registration for a struct field calls this).
fn validate_nested<T>(v: T&, path: const u8[:], out: Issues&) {
    let rs = rules_for(v);
    validate_fields(v, rs, 18446744073709551615, 0, path, out);
    if out.items.len == 0 { validate_model(v, out); }
}

// Validates a value whose fields are present as the bit masks say. Issues are appended to out,
// and root names where they came from ("body", "query", "form", "settings").
fn validate_present<T>(v: T&, root: const u8[:], present: u64, failed: u64, out: Issues&) {
    issues_root(out, root);
    let rs = rules_for(v);
    validate_fields(v, rs, present, failed, "", out);
    if out.items.len == 0 { validate_model(v, out); }
}

// Validates a complete value (every field counts as present).
fn validate<T>(v: T&, root: const u8[:], out: Issues&) {
    validate_present(v, root, 18446744073709551615, 0, out);
}

// --- startup check -----------------------------------------------------------------------

// Whether a text value of max_len bytes fits the capacity of field `name` of T. Decodes a probe
// string through the same reader the codec uses, so every limited type is covered.
fn field_fits<T>(v: T&, name: const u8[:], max_len: i64) -> bool {
    var text: u8[>..] = [];
    text.push('"');
    for i in max_len { text.push('a'); }
    text.push('"');
    var d = JsonDecoder { r: json::reader(text[..]), .. };
    const for <N, A> in fields<T> {
        if name == N {
            json_read_value(d, v.A);
        }
    }
    return !(d.count > 0 && d.first[..] == "string too long");
}

fn has_field<T>(name: const u8[:]) -> bool {
    const for <N, A> in fields<T> {
        if name == N { return true; }
    }
    return false;
}

// Validates the rules table of T against its fields. Returns false with the first problem.
fn check_rules<T>() -> bool, u8[>..] {
    var sample: T = T { .. };
    let rs = rules_for(sample);
    if rs.overflow { return false, str("more than ", RULES_MAX, " field rules"); }
    for i in rs.items.len {
        let rule = rs.items[i];
        let name = rule.name[..];
        if !has_field<T>(name) { return false, str("unknown field: ", name); }
        for j in i {
            if rs.items[j].name[..] == name { return false, str("duplicate rule for field: ", name); }
        }
        if rule.has_min_len && rule.min_len < 0 { return false, str("min_len must not be negative: ", name); }
        if rule.has_max_len && rule.max_len < 0 { return false, str("max_len must not be negative: ", name); }
        if rule.has_min_len && rule.has_max_len && rule.min_len > rule.max_len {
            return false, str("min_len is above max_len: ", name);
        }
        if rule.has_min_items && rule.has_max_items && rule.min_items > rule.max_items {
            return false, str("min_items is above max_items: ", name);
        }
        if rule.has_ge && rule.has_le && rule.ge > rule.le { return false, str("ge is above le: ", name); }
        if rule.has_gt && rule.has_lt && rule.gt >= rule.lt { return false, str("gt is not below lt: ", name); }
        if rule.has_multiple && rule.multiple_of <= 0 { return false, str("multiple_of must be positive: ", name); }
        if rule.has_max_len && rule.max_len <= RULE_PROBE_MAX && !field_fits(sample, name, rule.max_len) {
            return false, str("max_len is above the capacity of field: ", name);
        }
    }
    return true, str("");
}

// --- the 422 envelope ----------------------------------------------------------------------

// Writes one JSON string per dot-separated segment of loc: "inner.tags" -> ["inner","tags"].
fn issue_loc_json(out: u8[>..]&, loc: const u8[:]) {
    var start: i64 = 0;
    var first = true;
    loop {
        let dot = find(loc[start..], ".");
        let end = if dot < 0 { loc.len } else { start + dot };
        if !first { out.push(','); }
        first = false;
        json::format_string(out, loc[start..end]);
        if dot < 0 { break; }
        start = end + 1;
    }
}

// Writes the 422 envelope: the existing error object (code, and the first issue as
// "field: message"), then detail (one entry per issue, Pydantic-shaped) and truncated.
fn issues_fail(c: Ctx&, code: const u8[:], issues: Issues&) {
    let first = issues.items[0];
    var message: u8[>..] = [];
    if first.loc.len > 0 {
        message = str(first.loc[..], ": ", first.msg[..]);
    } else {
        message = str(first.msg[..]);
    }
    var body: u8[>..] = [];
    body.append("{\"error\":{\"code\":");
    json::format_string(body, code);
    body.append(",\"message\":");
    json::format_string(body, message[..]);
    body.append("},\"detail\":[");
    for i in issues.items.len {
        let item = issues.items[i];
        if i > 0 { body.push(','); }
        body.append("{\"loc\":[");
        json::format_string(body, issues.root[..]);
        if item.loc.len > 0 {
            body.push(',');
            issue_loc_json(body, item.loc[..]);
        }
        body.append("],\"msg\":");
        json::format_string(body, item.msg[..]);
        body.append(",\"type\":");
        json::format_string(body, item.kind[..]);
        body.push('}');
    }
    body.append("],\"truncated\":");
    body.append(if issues.truncated { "true" } else { "false" });
    body.append("}\n");
    if !valid_utf8(body[..]) {
        fail(c, HTTP_INTERNAL_SERVER_ERROR, "encode_error", "Validation message is not valid UTF-8");
        return;
    }
    status(c, HTTP_UNPROCESSABLE_CONTENT);
    write_body(c, CONTENT_TYPE_JSON, body[..]);
}

// Normalizes and validates a decoded value, with the decoder's issues first. Returns true when
// nothing is left to report. Otherwise writes the 422 envelope (code invalid_payload for a body,
// invalid_<root> for query and form) and returns false.
fn validate_result<T>(c: Ctx&, root: const u8[:], value: T&, result: DecodeResult) -> bool {
    // A response already written (a 400 or 415 from the decoder) is final: nothing more to report.
    if c.written { return false; }
    var issues = result.issues;
    if issues.items.len == 0 { normalize(value); }
    validate_present(value, root, result.present, result.failed, issues);
    if issues.items.len == 0 { return true; }
    var code: u8[>..] = [];
    if root == "body" { code = str("invalid_payload"); } else { code = str("invalid_", root); }
    issues_fail(c, code[..], issues);
    return false;
}
