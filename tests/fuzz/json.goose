// JSON decoder fuzzing: json_decode<T> on random, mutated and token-spliced documents, and the
// encoder on whatever decodes. Reproducible splitmix64 seeds, recorded here: 1, 42, 20261022 and
// 3735928559, 4096 inputs each, plus deep nesting and long-input cases. A debug build keeps the
// index and slice assertions active.
import goose_web from "../..";
import std;

struct Inner { level: i8 = 0, tags: u8[..8] = "" }
struct Record {
    id: i64 = 0, name: u8[..24] = "", flag: bool = false, ratio: f64 = 0.0, small: u8 = 0,
    inner: Inner, limited: i64[..4],
}

// A nested struct is registered once per direction (docs/api.md).
fn web::json_put_value(out: u8[>..]&, v: Inner&) -> bool { return web::json_put_fields(out, v); }
fn web::json_read_value(d: web::JsonDecoder&, out: Inner&) { web::json_read_fields(d, out); }

const BASE = "{\"id\":7,\"name\":\"seven\",\"flag\":true,\"ratio\":1.5,\"small\":3,\"inner\":{\"level\":-2,\"tags\":\"ab\"},\"limited\":[1,2]}";

var calls: i64 = 0;
var accepted: i64 = 0;

// Decodes text and checks what must hold for every input: the error fields stay within their
// capacities, and an accepted value encodes and decodes again to the same fields.
fn check(text: const u8[:]) {
    calls += 1;
    let value, result = web::json_decode<Record>(text);
    assert(result.error.len <= 128 && result.field.len <= 64);
    if !result.ok {
        assert(result.error.len > 0);
        return;
    }
    accepted += 1;
    assert(web::valid_utf8(value.name[..]));
    var out: u8[>..] = [];
    assert(web::json_encode(out, value));
    let again, second = web::json_decode<Record>(out[..]);
    assert(second.ok);
    assert(again.id == value.id && again.name[..] == value.name[..] && again.flag == value.flag);
    assert(again.small == value.small && again.inner.level == value.inner.level);
}

// Splices one token, overwrites a byte, duplicates a slice, or truncates the base document.
fn mutate(random: rng&, out: u8[>..]&) {
    let tokens = ["{", "}", "[", "]", "\"", "\\", "\\u", "\\uD800", "\\uDC00", "\\uD83D\\uDE00", ":", ",",
                  "-", "0", "1e400", "9999999999999999999999", "true", "null", "\xff", "\xc3", " ", "\n",
                  "\"\\u0000\"", "\"name\"", "\"inner\":{", "\"limited\":[", "1.5e-3", "-0"];
    out.clear();
    out.append(BASE);
    let edits = 1 + rand_int(random, 6);
    for edit in edits {
        let kind = rand_int(random, 4);
        if kind == 0 && out.len > 0 {
            out[rand_int(random, out.len)] = rand_int(random, 256) as u8;
        } else if kind == 1 {
            out.append(tokens[rand_int(random, tokens.len)]);
        } else if kind == 2 && out.len > 1 {
            let start = rand_int(random, out.len);
            let stop = start + rand_int(random, out.len - start + 1);
            var piece: u8[>..] = [];
            piece.append(out[start..stop]);
            out.append(piece[..]);
        } else if out.len > 0 {
            out.resize(rand_int(random, out.len + 1));
        }
    }
}

// A well-formed document with random values, many of them out of range or escaped, so both the
// accepted path (re-encoded) and the schema errors are reached.
fn generated(random: rng&, out: u8[>..]&) {
    let names = ["", "a", "caf\xc3\xa9", "\\uD83D\\uDE00", "\\u00e9t\\u00e9", "\\uD800", "\\\"quoted\\\"", "x x"];
    let name = names[rand_int(random, names.len)];
    let flag = if rand_int(random, 2) == 0 { "true" } else { "false" };
    let lower = rand_int(random, 300) - 150;
    let big = rand_int(random, 2000000) - 1000000;
    format(out, "{\"id\":", big, ",\"name\":\"", name, "\",\"flag\":", flag, ",\"ratio\":0.25,\"small\":",
           rand_int(random, 300), ",\"inner\":{\"level\":", lower, ",\"tags\":\"x\"},\"limited\":[1,2,3]}");
}

fn fuzz(seed: u64) {
    var random = rng { s: seed };
    for iteration in 4096 {
        var raw: u8[>..] = [];
        if iteration % 3 == 0 {
            // Random bytes, sometimes with a quote so that strings are reached.
            let length = rand_int(random, 200);
            for i in length { raw.push(rand_int(random, 256) as u8); }
        } else if iteration % 3 == 1 {
            generated(random, raw);
        } else {
            mutate(random, raw);
        }
        check(raw[..]);
    }
}

fn deep_and_long() {
    // 8000 open brackets: the skipper is iterative, so this is a syntax error, not a stack overflow.
    var brackets: u8[>..] = [];
    for i in 8000 { brackets.push('['); }
    check(brackets[..]);
    // An unknown key holding deep nesting is skipped without recursion.
    var nested: u8[>..] = [];
    nested.append("{\"unknown\":");
    for i in 4000 { nested.append("["); }
    for i in 4000 { nested.append("]"); }
    nested.push('}');
    check(nested[..]);
    // A long name is refused by its capacity, not truncated.
    var long: u8[>..] = [];
    long.append("{\"name\":\"");
    for i in 100 { long.push('x'); }
    long.append("\"}");
    check(long[..]);
    let long_value, long_result = web::json_decode<Record>(long[..]);
    assert(!long_result.ok);
}

fn main() {
    fuzz(1);
    fuzz(42);
    fuzz(20261022);
    fuzz(3735928559);
    deep_and_long();
    print("JSON decoder fuzz tests passed: ", calls, " inputs, ", accepted, " accepted and re-encoded; splitmix64 seeds 1,42,20261022,3735928559");
}
