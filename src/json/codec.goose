// JSON codec: structs to and from JSON objects, driven by fields<T>. Contract: docs/api.md.
//
// Overloads cannot tell a struct from a limited array: a generic T& beats any coercion,
// and both are generic T&. So scalars and literal text take exact concrete overloads,
// arrays and text fields share the generic T& catch-all (text or list picked by slice
// overloads), and nested structs need a one-line registration (docs/api.md).
namespace web;
import std;
import json;
import src.http.errors;
import src.json.issues;

// ok, syntax (malformed text, nothing read), error and field (the first issue's raw message and
// path, kept for callers that report one error), present (bit i: field i had a key) and failed
// (bit i: field i had a schema error, so its value is not to be trusted). issues lists every
// schema error found, in order, and is empty when ok.
struct DecodeResult { ok: bool, syntax: bool, error: u8[..128], field: u8[..64], present: u64, failed: u64, issues: Issues }

// The stdlib reader plus the decode state. A schema error is recorded as an issue and decoding
// goes on with the next field (json_member): field is the key being read, scope the dotted path
// of the object around it ("" at the top, "address." inside a nested struct). count is every
// issue so far (the issues list is bounded, the count is not).
struct JsonDecoder {
    r: json::Reader,
    field: u8[..64],
    scope: u8[..64],
    first: u8[..128],
    first_field: u8[..64],
    count: i64,
    issues: Issues,
}

// --- field hooks ----------------------------------------------------------------
// json_key(v, field): the JSON name of a field (default: its declared name). json_skip(v, field):
// true keeps the field out of JSON both ways. Both are keyed by the declared name from fields<T>,
// and an application overloads either for its struct (docs/api.md, "Field names and skipping").
// Calls with the declared name stay the same for has<T> and SQL columns.
fn json_key<T>(v: T&, field: const u8[:]) -> const u8[:] { return field; }
fn json_skip<T>(v: T&, field: const u8[:]) -> bool { return false; }

// Whether the JSON names of T's live fields are unique. On a conflict the report gets the
// first duplicate name and the result is false. Skipped fields do not take part.
fn json_key_report<T>(out: u8[>..]&) -> bool {
    var v: T = T { .. };
    var dup: const u8[:] = "";
    var i: i64 = 0;
    const for <N, A> in fields<T> {
        var j: i64 = 0;
        const for <M, B> in fields<T> {
            if i != j && dup.len == 0 && !json_skip(v, N) && !json_skip(v, M) && json_key(v, N) == json_key(v, M) {
                dup = json_key(v, N);
            }
            j += 1;
        }
        i += 1;
    }
    if dup.len > 0 {
        out.append("duplicate JSON key: ");
        out.append(dup);
        return false;
    }
    return true;
}

// Startup probe: true when T's JSON names are unique. Encode, decode and query<T> check the same
// thing at use and fail with a message, so a conflict never reaches the wire unnoticed.
fn check_json_keys<T>() -> bool {
    var scratch: u8[>..] = [];
    return json_key_report<T>(scratch);
}

// --- encoding -------------------------------------------------------------------

fn json_put_value(out: u8[>..]&, v: i64) -> bool { json::format_int(out, v); return true; }
fn json_put_value(out: u8[>..]&, v: i32) -> bool { json::format_int(out, v); return true; }
fn json_put_value(out: u8[>..]&, v: i16) -> bool { json::format_int(out, v); return true; }
fn json_put_value(out: u8[>..]&, v: i8) -> bool { json::format_int(out, v); return true; }
fn json_put_value(out: u8[>..]&, v: u64) -> bool { format(out, v); return true; }
fn json_put_value(out: u8[>..]&, v: u32) -> bool { json::format_int(out, v); return true; }
fn json_put_value(out: u8[>..]&, v: u16) -> bool { json::format_int(out, v); return true; }
fn json_put_value(out: u8[>..]&, v: u8) -> bool { json::format_int(out, v); return true; }
fn json_put_value(out: u8[>..]&, v: bool) -> bool { json::format_bool(out, v); return true; }
// f32 is written as its f64 value, so 0.1f32 comes out as 0.10000000149011612.
fn json_put_value(out: u8[>..]&, v: f32) -> bool { json::format_number(out, v); return true; }
fn json_put_value(out: u8[>..]&, v: f64) -> bool { json::format_number(out, v); return true; }
fn json_put_value(out: u8[>..]&, v: const u8[:]) -> bool { return json_put_seq(out, v); }

// Arrays and text: the slice decides. Only a u8 slice is text.
fn json_put_value<T>(out: u8[>..]&, v: T&) -> bool { return json_put_seq(out, v[..]); }

fn json_put_seq(out: u8[>..]&, s: const u8[:]) -> bool {
    if !valid_utf8(s) { return false; }
    json::format_string(out, s);
    return true;
}

fn json_put_seq<E>(out: u8[>..]&, s: E[:]) -> bool {
    out.push('[');
    for i in s.len {
        if i > 0 { out.push(','); }
        if !json_put_value(out, s[i]) { return false; }
    }
    out.push(']');
    return true;
}

fn json_put_fields<T>(out: u8[>..]&, v: T&) -> bool {
    if !check_json_keys<T>() { return false; }
    out.push('{');
    var first = true;
    const for <N, A> in fields<T> {
        if !json_skip(v, N) {
            if !first { out.push(','); }
            first = false;
            json::format_key(out, json_key(v, N));
            if !json_put_value(out, v.A) { return false; }
        }
    }
    out.push('}');
    return true;
}

// Top level: a struct, a scalar, or literal text. On false, out is unchanged.
fn json_encode<T>(out: u8[>..]&, value: T) -> bool {
    let start = out.len;
    if json_put_fields(out, value) { return true; }
    out.pop_n(out.len - start);
    return false;
}
fn json_encode(out: u8[>..]&, value: i64) -> bool { return json_put_value(out, value); }
fn json_encode(out: u8[>..]&, value: const u8[:]) -> bool {
    let start = out.len;
    if json_put_value(out, value) { return true; }
    out.pop_n(out.len - start);
    return false;
}

// --- decoding -------------------------------------------------------------------

// Records one schema issue at the current path. raw is the reader-style text the legacy
// DecodeResult.error carries for the first issue, and the legacy DecodeResult.field is its
// innermost key; kind and msg are the Pydantic type id and text, and loc the full dotted path.
fn json_issue(d: JsonDecoder&, raw: const u8[:], kind: const u8[:], msg: const u8[:]) {
    let path = str(d.scope[..], d.field[..]);
    if d.count == 0 {
        json_store(d.first, raw);
        json_store(d.first_field, d.field[..]);
    }
    d.count += 1;
    issue_add(d.issues, path[..], kind, msg);
}

// Records a schema issue and stops the reader at this value. json_member moves past the value.
fn json_reject(d: JsonDecoder&, raw: const u8[:], kind: const u8[:], msg: const u8[:]) {
    json_issue(d, raw, kind, msg);
    json::fail(d.r, raw);
}

// Fatal for the reader only: used for the syntax of a value the reader cannot read at all.
fn json_fail(d: JsonDecoder&, what: const u8[:]) { json::fail(d.r, what); }

// Keeps the key as the field name, cut to the field's capacity.
fn json_set_field(d: JsonDecoder&, key: const u8[:]) {
    d.field.clear();
    let n = if key.len > d.field.cap { d.field.cap } else { key.len };
    d.field.append(key[..n]);
}

// Copies text into a bounded string, cut to its capacity.
fn json_store<T>(dst: T&, text: const u8[:]) {
    dst.clear();
    let n = if text.len > dst.cap { dst.cap } else { text.len };
    dst.append(text[..n]);
}

fn json_int_in(d: JsonDecoder&, lo: i64, hi: i64) -> i64 {
    let v = json::read_int(d.r);
    if d.r.error.len > 0 { return 0; }
    if v < lo {
        json_issue(d, "integer out of range", "greater_than_equal", str("Input should be greater than or equal to ", lo));
        return 0;
    }
    if v > hi {
        json_issue(d, "integer out of range", "less_than_equal", str("Input should be less than or equal to ", hi));
        return 0;
    }
    return v;
}

fn json_read_value(d: JsonDecoder&, out: i64&) { out = json::read_int(d.r); }
fn json_read_value(d: JsonDecoder&, out: i32&) { out = json_int_in(d, -2147483648, 2147483647) as i32; }
fn json_read_value(d: JsonDecoder&, out: i16&) { out = json_int_in(d, -32768, 32767) as i16; }
fn json_read_value(d: JsonDecoder&, out: i8&) { out = json_int_in(d, -128, 127) as i8; }
fn json_read_value(d: JsonDecoder&, out: u64&) { out = json_int_in(d, 0, 9223372036854775807) as u64; }
fn json_read_value(d: JsonDecoder&, out: u32&) { out = json_int_in(d, 0, 4294967295) as u32; }
fn json_read_value(d: JsonDecoder&, out: u16&) { out = json_int_in(d, 0, 65535) as u16; }
fn json_read_value(d: JsonDecoder&, out: u8&) { out = json_int_in(d, 0, 255) as u8; }
fn json_read_value(d: JsonDecoder&, out: bool&) { out = json::read_bool(d.r); }
fn json_read_value(d: JsonDecoder&, out: f64&) { out = json::read_number(d.r); }
fn json_read_value(d: JsonDecoder&, out: f32&) { out = json::read_number(d.r) as f32; }

// A slice view of u8 elements: the text form. Only a u8 array is a string.
fn json_is_bytes(s: u8[:]) -> bool { return true; }
fn json_is_bytes<E>(s: E[:]) -> bool { return false; }

// Copies bytes into a u8 array of the same length; never called for other arrays.
fn json_copy_bytes(dst: u8[:], src: const u8[:]) { for i in src.len { dst[i] = src[i]; } }
fn json_copy_bytes<E>(dst: E[:], src: const u8[:]) { }

// A default element, to grow an array by: limited element types are fixed-size.
fn json_elem_default<E>(s: E[:]) -> E { return default<E>(); }

fn json_read_value<T>(d: JsonDecoder&, out: T&) {
    if json::peek(d.r) == '"' {
        var scratch: u8[>..] = [];
        let text = json::read_string(d.r, scratch);
        if d.r.error.len > 0 { return; }
        // Escapes can make bytes the input never held: a lone surrogate (\uD800) decodes to
        // three bytes that are not UTF-8. Such text is refused here, so every decoded field
        // is valid UTF-8 and the encoder's own check never fails on it later.
        if !valid_utf8(text) { json_fail(d, "invalid UTF-8 in string"); return; }
        if !json_is_bytes(out[..]) { json_fail(d, "expected an array"); return; }
        if text.len > out.cap {
            json_reject(d, "string too long", "string_too_long", str("String should have at most ", out.cap, " characters"));
            return;
        }
        out.resize(text.len, json_elem_default(out[..]));
        json_copy_bytes(out[..], text);
        return;
    }
    if json_is_bytes(out[..]) { json_fail(d, "expected a string"); return; }
    json_read_list(d, out);
}

// Limited arrays only (they have a cap): a full one fails the read instead of aborting.
fn json_read_list<T>(d: JsonDecoder&, out: T&) {
    out.clear();
    json::each_element(d.r) {
        if out.len == out.cap {
            json_reject(d, "array too long", "too_long", str("List should have at most ", out.cap, " items"));
            return;
        }
        out.resize(out.len + 1, json_elem_default(out[..]));
        json_read_value(d, out[out.len - 1]);
    };
}

// Maps a reader error that no issue explains to its Pydantic type id.
fn json_issue_raw(d: JsonDecoder&, raw: const u8[:]) {
    if raw == "expected an integer" { json_issue(d, raw, "int_type", "Input should be a valid integer"); }
    else if raw == "expected a number" { json_issue(d, raw, "float_type", "Input should be a valid number"); }
    else if raw == "expected true or false" { json_issue(d, raw, "bool_type", "Input should be a valid boolean"); }
    else if raw == "expected a string" { json_issue(d, raw, "string_type", "Input should be a valid string"); }
    else if raw == "expected an array" { json_issue(d, raw, "list_type", "Input should be a valid list"); }
    else if raw == "expected '{'" { json_issue(d, raw, "model_type", "Input should be a valid object"); }
    else { json_issue(d, raw, "value_error", raw); }
}

// Reads the value of one member. A schema error is recorded, the reader goes back to the value,
// skips it, and decoding goes on with the next member. Returns false when the value had an error
// (an issue was recorded for it, or the reader failed on it).
fn json_member<T>(d: JsonDecoder&, out: T&) -> bool {
    json::peek(d.r);
    let start = d.r.pos;
    let before = d.count;
    json_read_value(d, out);
    if d.r.error.len == 0 { return d.count == before; }
    if d.count == before { json_issue_raw(d, d.r.error); }
    d.r.error = "";
    d.r.error_at = 0;
    d.r.pos = start;
    json::skip(d.r);
    return false;
}

// Reads one object into out. Returns the bit mask of the fields present; failed gets the bits of
// the fields whose value had a schema error. Nested objects extend the scope with their key.
fn json_read_fields_level<T>(d: JsonDecoder&, out: T&, failed: u64&) -> u64 {
    var count: i64 = 0;
    const for <N, A> in fields<T> { count++; }
    if count > 64 { abort("json: a struct has more than 64 fields"); }
    failed = 0;
    if !check_json_keys<T>() {
        json_issue(d, "duplicate JSON key name", "value_error", "duplicate JSON key name");
        return 0;
    }
    let outer = d.scope;
    if d.field.len > 0 { json_store(d.scope, str(outer[..], d.field[..], ".")); }
    var seen: u64 = 0;
    json::each_member(d.r) { key =>
        json_set_field(d, key);
        var known = false;
        var bit: u64 = 1;
        const for <N, A> in fields<T> {
            // A skipped field is unknown on the wire, as if the struct did not declare it.
            if !json_skip(out, N) && key == json_key(out, N) {
                known = true;
                if (seen & bit) != 0 {
                    json_issue(d, "duplicate key", "value_error", "Duplicate key");
                    json::skip(d.r);
                } else {
                    seen |= bit;
                    if !json_member(d, out.A) { failed |= bit; }
                }
            }
            bit <<= 1;
        }
        if !known {
            json_issue(d, "unknown key", "extra_forbidden", "Extra inputs are not permitted");
            json::skip(d.r);
        }
    };
    if d.r.error.len > 0 { json_issue_raw(d, d.r.error); }
    d.scope = outer;
    return seen;
}

// Reads one object into out; returns the bit mask of the fields present.
fn json_read_fields<T>(d: JsonDecoder&, out: T&) -> u64 {
    var failed: u64 = 0;
    return json_read_fields_level(d, out, failed);
}

// Strict decode of text into a T: syntax is checked first, on the whole text, so a
// later failure is a schema problem. Schema errors are collected (see DecodeResult). Missing
// keys keep the declared defaults.
fn json_decode<T>(text: const u8[:]) -> T, DecodeResult {
    var result = DecodeResult { .. };
    var value: T = T { .. };
    if !valid_utf8(text) {
        json_store(result.error, "invalid UTF-8");
        result.syntax = true;
        return value, result;
    }
    var check = json::reader(text);
    json::skip(check);
    if !json::finish(check) {
        json_store(result.error, check.error);
        result.syntax = true;
        return value, result;
    }
    var d = JsonDecoder { r: json::reader(text), .. };
    var failed: u64 = 0;
    let present = json_read_fields_level(d, value, failed);
    result.present = present;
    result.failed = failed;
    if d.count > 0 {
        json_store(result.error, d.first[..]);
        json_store(result.field, d.first_field[..]);
        result.issues = d.issues;
        return value, result;
    }
    result.ok = true;
    return value, result;
}

// Whether field `name` of T was present in a decode that produced result.
fn has<T>(result: DecodeResult, name: const u8[:]) -> bool {
    var bit: u64 = 1;
    const for <N, A> in fields<T> {
        if name == N { return (result.present & bit) != 0; }
        bit <<= 1;
    }
    return false;
}
