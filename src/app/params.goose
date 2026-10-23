import src.constants.http;
import src.constants.limits;
import src.http.errors;
import src.http.request;
import src.http.headers;
import src.json.codec;
import src.routing.router;
import src.app.context;
import std;
namespace web;

// Typed query strings: query<T>(c) binds the query into struct T by field name. The rules
// match body<T>: strict (unknown keys and duplicate keys are errors), missing keys keep the
// declared default, and a failure writes 400 invalid_query and returns false. Empty pairs
// ("a=1&&b=2", a trailing "&") are skipped. Keys and values are decoded by query_decode
// (percent escapes, '+' as space).
//
// form<T>(c) binds an application/x-www-form-urlencoded body with the same rules. A wrong
// media type writes 415; a decode failure writes 400 invalid_form.
//
// Supported field types: i8..i64, u8..u64, bool, f32, f64 and u8[..N]. Integers are canonical
// decimal: an optional '-' (signed types only), no '+', no leading zeros, range-checked.
// bool accepts true, false, 1 and 0. Floats use the stdlib parse_flt. Strings must be valid
// UTF-8 and fit their capacity.

const QUERY_I64_MIN = -9223372036854775807 - 1;
const QUERY_I64_MAX = 9223372036854775807;
const QUERY_U64_MAX = 18446744073709551615;

// Canonical decimal into a magnitude. A '-' sets `negative` only when negative_ok.
fn query_magnitude(raw: const u8[:], negative_ok: bool, reason: u8[..128]&, negative: bool&, magnitude: u64&) -> bool {
    negative = false;
    var pos: i64 = 0;
    if raw.len > 0 && raw[0] == '-' {
        if !negative_ok {
            json_store(reason, "must not be negative");
            return false;
        }
        negative = true;
        pos = 1;
    }
    let digits = raw[pos..];
    if digits.len == 0 || (digits[0] == '0' && digits.len > 1) || (negative && digits[0] == '0') {
        json_store(reason, "expected an integer");
        return false;
    }
    var value: u64 = 0;
    // u64 max / 10, with the last digit allowed up to 5.
    let limit: u64 = 1844674407370955161;
    for ch in digits {
        if ch < '0' || ch > '9' {
            json_store(reason, "expected an integer");
            return false;
        }
        let digit = (ch - '0') as u64;
        if value > limit || (value == limit && digit > 5) {
            json_store(reason, "integer out of range");
            return false;
        }
        value = value * 10 + digit;
    }
    magnitude = value;
    return true;
}

// Signed value within [lo, hi]. lo <= 0 <= hi, hi <= i64 max. Works for lo at i64 min.
fn query_signed(raw: const u8[:], lo: i64, hi: i64, reason: u8[..128]&, out: i64&) -> bool {
    var negative = false;
    var magnitude: u64 = 0;
    if !query_magnitude(raw, lo < 0, reason, negative, magnitude) { return false; }
    if negative {
        // The magnitude is at least 1 here ("-0" is rejected above).
        if magnitude - 1 > (-(lo + 1)) as u64 {
            json_store(reason, "integer out of range");
            return false;
        }
        out = -((magnitude - 1) as i64) - 1;
        return true;
    }
    if magnitude > hi as u64 {
        json_store(reason, "integer out of range");
        return false;
    }
    out = magnitude as i64;
    return true;
}

fn query_unsigned(raw: const u8[:], hi: u64, reason: u8[..128]&, out: u64&) -> bool {
    var negative = false;
    var magnitude: u64 = 0;
    if !query_magnitude(raw, false, reason, negative, magnitude) { return false; }
    if magnitude > hi {
        json_store(reason, "integer out of range");
        return false;
    }
    out = magnitude;
    return true;
}

// Per-type readers. Concrete overloads beat the generic string reader below.
fn query_read(raw: const u8[:], out: i64&, reason: u8[..128]&) -> bool {
    return query_signed(raw, QUERY_I64_MIN, QUERY_I64_MAX, reason, out);
}
fn query_read(raw: const u8[:], out: i32&, reason: u8[..128]&) -> bool {
    var value: i64 = 0;
    if !query_signed(raw, -2147483648, 2147483647, reason, value) { return false; }
    out = value as i32;
    return true;
}
fn query_read(raw: const u8[:], out: i16&, reason: u8[..128]&) -> bool {
    var value: i64 = 0;
    if !query_signed(raw, -32768, 32767, reason, value) { return false; }
    out = value as i16;
    return true;
}
fn query_read(raw: const u8[:], out: i8&, reason: u8[..128]&) -> bool {
    var value: i64 = 0;
    if !query_signed(raw, -128, 127, reason, value) { return false; }
    out = value as i8;
    return true;
}
fn query_read(raw: const u8[:], out: u64&, reason: u8[..128]&) -> bool {
    return query_unsigned(raw, QUERY_U64_MAX, reason, out);
}
fn query_read(raw: const u8[:], out: u32&, reason: u8[..128]&) -> bool {
    var value: u64 = 0;
    if !query_unsigned(raw, 4294967295, reason, value) { return false; }
    out = value as u32;
    return true;
}
fn query_read(raw: const u8[:], out: u16&, reason: u8[..128]&) -> bool {
    var value: u64 = 0;
    if !query_unsigned(raw, 65535, reason, value) { return false; }
    out = value as u16;
    return true;
}
fn query_read(raw: const u8[:], out: u8&, reason: u8[..128]&) -> bool {
    var value: u64 = 0;
    if !query_unsigned(raw, 255, reason, value) { return false; }
    out = value as u8;
    return true;
}
fn query_read(raw: const u8[:], out: bool&, reason: u8[..128]&) -> bool {
    if raw == "true" || raw == "1" {
        out = true;
        return true;
    }
    if raw == "false" || raw == "0" {
        out = false;
        return true;
    }
    json_store(reason, "expected true, false, 1 or 0");
    return false;
}
fn query_read(raw: const u8[:], out: f64&, reason: u8[..128]&) -> bool {
    let value, ok = parse_flt(raw);
    if !ok {
        json_store(reason, "expected a number");
        return false;
    }
    out = value;
    return true;
}
fn query_read(raw: const u8[:], out: f32&, reason: u8[..128]&) -> bool {
    let value, ok = parse_flt(raw);
    if !ok {
        json_store(reason, "expected a number");
        return false;
    }
    out = value as f32;
    return true;
}
// Limited strings (u8[..N]): the decoded bytes must be UTF-8 and fit the capacity.
fn query_read<T>(raw: const u8[:], out: T&, reason: u8[..128]&) -> bool {
    if raw.len > out.cap {
        json_store(reason, "string too long");
        return false;
    }
    if !valid_utf8(raw) {
        json_store(reason, "invalid UTF-8");
        return false;
    }
    out.clear();
    out.append(raw);
    return true;
}

// Binds a query string (or a form body, which uses the same pair syntax) into T. On failure,
// error holds the reason, field the key (or empty), and ok is false. present has bit i set
// for field i in declaration order.
fn pairs_result<T>(query: const u8[:]) -> T, DecodeResult {
    var value: T = T { .. };
    var result = DecodeResult { .. };
    var seen: u64 = 0;
    var pos: i64 = 0;
    while pos < query.len {
        let amp = find(query[pos..], "&");
        let end = if amp < 0 { query.len } else { pos + amp };
        let pair = query[pos..end];
        pos = end + 1;
        if pair.len == 0 { continue; }
        let equals = find(pair, "=");
        let name_raw = if equals < 0 { pair } else { pair[..equals] };
        let value_raw = if equals < 0 { pair[pair.len..] } else { pair[equals + 1..] };
        let name = query_decode(name_raw);
        let text = query_decode(value_raw);
        if name.status != HTTP_OK || text.status != HTTP_OK {
            json_store(result.error, "query string could not be decoded");
            return value, result;
        }
        let key = name.value[..];
        var known = false;
        var bit: u64 = 1;
        const for <N, A> in fields<T> {
            if !known && key == N {
                known = true;
                if (seen & bit) != 0 {
                    json_store(result.error, "duplicate query parameter");
                    json_store(result.field, N);
                    return value, result;
                }
                seen |= bit;
                if !query_read(text.value[..], value.A, result.error) {
                    json_store(result.field, N);
                    return value, result;
                }
            }
            bit <<= 1;
        }
        if !known {
            json_store(result.error, "unknown key");
            json_store(result.field, key);
            return value, result;
        }
    }
    result.ok = true;
    result.present = seen;
    return value, result;
}

// Binds the query of the request target into T. See pairs_result for the result.
fn query_result<T>(c: Ctx&) -> T, DecodeResult {
    let value, result = pairs_result<T>(target_query(c.request.target));
    return value, result;
}

// Binds the query into T, or writes 400 invalid_query "field: reason" and returns false.
fn query<T>(c: Ctx&) -> T, bool {
    let value, result = query_result<T>(c);
    if result.ok { return value, true; }
    let message = if result.field.len == 0 {
        str(result.error[..])
    } else {
        str(result.field[..], ": ", result.error[..])
    };
    // A key with bytes that are not UTF-8 cannot go into the JSON envelope.
    if !valid_utf8(message[..]) {
        fail(c, HTTP_BAD_REQUEST, "invalid_query", "Query parameter name is not valid UTF-8");
        return value, false;
    }
    fail(c, HTTP_BAD_REQUEST, "invalid_query", message[..]);
    return value, false;
}

// Media type only, compared case-insensitively; parameters such as charset are ignored.
fn is_form_media_type(value: const u8[:]) -> bool {
    let semi = find(value, ";");
    let base = request_ows(if semi < 0 { value } else { value[..semi] });
    return equal_header(base, CONTENT_TYPE_FORM);
}

// Binds the form body into T, or writes 415 for another media type and 400 invalid_form
// for a bad pair. Missing keys keep their defaults; an empty body binds all defaults.
fn form<T>(c: Ctx&) -> T, bool {
    var value: T = T { .. };
    if !is_form_media_type(c.header(HEADER_CONTENT_TYPE)) {
        fail(c, HTTP_UNSUPPORTED_MEDIA_TYPE, "unsupported_media_type", "Content-Type must be application/x-www-form-urlencoded");
        return value, false;
    }
    let bound, result = pairs_result<T>(c.request.body);
    if result.ok { return bound, true; }
    let message = if result.field.len == 0 {
        str(result.error[..])
    } else {
        str(result.field[..], ": ", result.error[..])
    };
    if !valid_utf8(message[..]) {
        fail(c, HTTP_BAD_REQUEST, "invalid_form", "Form field name is not valid UTF-8");
        return bound, false;
    }
    fail(c, HTTP_BAD_REQUEST, "invalid_form", message[..]);
    return bound, false;
}
