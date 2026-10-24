// JSON codec: round trips, escaping, every decode error class, defaults, capacities.
import goose_web from "../..";
import std;

struct Point { x: i32, y: i32 }
struct Inner { level: i8, tags: u8[..8] }
struct Config { port: i64 = 8080, host: u8[..16] = "localhost", debug: bool = true }
struct Title { title: u8[..16], done: bool }
struct Limits { limited: i64[..4], labels: u8[..8][..2] }
struct Fixed { values: i64[3], grow: i64[>..] }
struct Series { id: i64, values: i64[>..] }
struct Everything {
    a: i8, b: i16, c: i32, d: i64, e: u8, f: u16, g: u32, h: u64,
    flag: bool, ratio: f32, big: f64,
    name: u8[..16], inner: Inner, limited: i64[..4], items: Inner[..2],
}

// A nested struct is registered with one overload per direction (see docs/api.md).
fn web::json_put_value(out: u8[>..]&, v: Inner&) -> bool { return web::json_put_fields(out, v); }
fn web::json_read_value(d: web::JsonDecoder&, out: Inner&) { web::json_read_fields(d, out); }

// Field hooks: `completed` is written as "done", `secret` is never written or read.
struct Renamed { id: i64, completed: bool, secret: i64 }
struct Wrapper { label: u8[..8], item: Renamed }
// Two fields with the same JSON name: a programmer error the codec reports at use.
struct Clash { a: bool, b: bool }

fn web::json_key(v: Renamed&, field: const u8[:]) -> const u8[:] {
    if field == "completed" { return "done"; }
    return field;
}
fn web::json_skip(v: Renamed&, field: const u8[:]) -> bool { return field == "secret"; }
fn web::json_put_value(out: u8[>..]&, v: Renamed&) -> bool { return web::json_put_fields(out, v); }
fn web::json_read_value(d: web::JsonDecoder&, out: Renamed&) { web::json_read_fields(d, out); }
fn web::json_key(v: Clash&, field: const u8[:]) -> const u8[:] { return "same"; }

fn encode<T>(value: T) -> u8[>..] {
    var out: u8[>..] = [];
    assert(web::json_encode(out, value));
    return copy(out);
}

fn expect_error<T>(text: const u8[:], error: const u8[:], field: const u8[:]) {
    let value, res = web::json_decode<T>(text);
    assert(!res.ok);
    assert(res.syntax == false);
    assert(res.error == error);
    assert(res.field == field);
}

fn expect_syntax<T>(text: const u8[:], error: const u8[:]) {
    let value, res = web::json_decode<T>(text);
    assert(!res.ok);
    assert(res.syntax == true);
    assert(res.error == error);
    assert(res.field.len == 0);
}

fn test_encode_compact() {
    let text = encode(Point { x: 1, y: -2 });
    assert(text == "{\"x\":1,\"y\":-2}");
    let empty = encode(Limits { limited: [], labels: ["", ""] });
    assert(empty == "{\"limited\":[],\"labels\":[\"\",\"\"]}");
    assert(encode(Fixed { values: [1, 2, 3], grow: [] }) == "{\"values\":[1,2,3],\"grow\":[]}");
}

fn test_encode_scalars() {
    let all = encode(Everything {
        a: -128, b: -32768, c: -2147483648, d: -9223372036854775808,
        e: 255, f: 65535, g: 4294967295, h: 18446744073709551615,
        flag: true, ratio: 1.5, big: 0.1,
        name: "n", inner: Inner { level: -5, tags: "t" }, limited: [4], items: [],
    });
    assert(find(all, "\"a\":-128,\"b\":-32768,\"c\":-2147483648,\"d\":-9223372036854775808") >= 0);
    assert(find(all, "\"e\":255,\"f\":65535,\"g\":4294967295,\"h\":18446744073709551615") >= 0);
    assert(find(all, "\"flag\":true,\"ratio\":1.5,\"big\":0.1") >= 0);
    assert(find(all, "\"inner\":{\"level\":-5,\"tags\":\"t\"},\"limited\":[4],\"items\":[]}") >= 0);
}

fn test_escaping() {
    let title = encode(Title { title: "a\"b\\c\n\t\x01/", done: false });
    assert(title == "{\"title\":\"a\\\"b\\\\c\\n\\t\\u0001/\",\"done\":false}");
    let back, res = web::json_decode<Title>(title);
    assert(res.ok && back.title == "a\"b\\c\n\t\x01/");
}

fn test_unicode() {
    let text = "{\"title\":\"caf\xc3\xa9 \xf0\x9f\xa5\x95\",\"done\":true}";
    let back, res = web::json_decode<Title>(text);
    assert(res.ok && back.title == "caf\xc3\xa9 \xf0\x9f\xa5\x95" && back.done);
    assert(encode(back) == text);
}

fn test_floats() {
    let back, res = web::json_decode<Everything>("{\"ratio\":2,\"big\":-1.25e2}");
    assert(res.ok && back.ratio == 2.0 && back.big == -125.0);
    let text = encode(Point { x: 0, y: 0 });
    assert(text == "{\"x\":0,\"y\":0}");
}

fn test_encode_failures() {
    var out: u8[>..] = [];
    out.append("keep;");
    assert(!web::json_encode(out, Title { title: "\xff", done: true }));
    assert(out == "keep;");
    assert(!web::json_encode(out, "\xc3"));
    assert(out == "keep;");
    assert(web::json_encode(out, 42));
    assert(out == "keep;42");
}

fn test_grow_array_encode() {
    var s = Series { id: 1, values: [] };
    s.values.push(4);
    s.values.push(5);
    assert(encode(s) == "{\"id\":1,\"values\":[4,5]}");
}

fn test_roundtrip_everything() {
    let source = Everything {
        a: 1, b: 2, c: 3, d: 4, e: 5, f: 6, g: 7, h: 8,
        flag: false, ratio: 0.25, big: 3.5,
        name: "every", inner: Inner { level: 9, tags: "in" },
        limited: [10, 11], items: [Inner { level: 1, tags: "a" }, Inner { level: 2, tags: "" }],
    };
    let text = encode(source);
    let back, res = web::json_decode<Everything>(text);
    assert(res.ok);
    assert(back.h == 8 && back.flag == false && back.ratio == 0.25 && back.big == 3.5);
    assert(back.name == "every" && back.inner.level == 9 && back.inner.tags == "in");
    assert(back.limited == [10, 11]);
    assert(back.items.len == 2 && back.items[1].level == 2);
    assert(encode(back) == text);
}

fn test_defaults_and_present() {
    let config, res = web::json_decode<Config>("{}");
    assert(res.ok && config.port == 8080 && config.host == "localhost" && config.debug);
    assert(!web::has<Config>(res, "port") && !web::has<Config>(res, "nope"));
    let other, res2 = web::json_decode<Config>("{\"debug\":false,\"port\":1}");
    assert(res2.ok && other.port == 1 && other.host == "localhost" && !other.debug);
    assert(web::has<Config>(res2, "debug") && web::has<Config>(res2, "port"));
    assert(!web::has<Config>(res2, "host"));
    assert(res2.present == 5);
}

fn test_decode_errors() {
    expect_error<Point>("{\"x\":1,\"y\":2,\"z\":3}", "unknown key", "z");
    expect_error<Point>("{\"x\":1,\"x\":2,\"y\":3}", "duplicate key", "x");
    expect_error<Point>("{\"x\":\"one\",\"y\":2}", "expected an integer", "x");
    expect_error<Point>("{\"x\":1.5,\"y\":2}", "expected an integer", "x");
    expect_error<Point>("{\"x\":2147483648,\"y\":2}", "integer out of range", "x");
    expect_error<Everything>("{\"a\":128}", "integer out of range", "a");
    expect_error<Everything>("{\"e\":-1}", "integer out of range", "e");
    expect_error<Everything>("{\"h\":-1}", "integer out of range", "h");
    expect_error<Everything>("{\"flag\":1}", "expected true or false", "flag");
    expect_error<Everything>("{\"big\":\"1\"}", "expected a number", "big");
    expect_error<Everything>("{\"name\":[1]}", "expected a string", "name");
    expect_error<Limits>("{\"labels\":\"ab\"}", "expected an array", "labels");
    expect_error<Limits>("{\"limited\":\"ab\"}", "expected an array", "limited");
    expect_error<Limits>("{\"limited\":[1,2,3,4,5]}", "array too long", "limited");
    expect_error<Limits>("{\"labels\":[\"a\",\"b\",\"c\"]}", "array too long", "labels");
    expect_error<Title>("{\"title\":\"0123456789abcdefX\"}", "string too long", "title");
    expect_error<Inner>("{\"tags\":\"123456789\"}", "string too long", "tags");
    expect_error<Everything>("{\"inner\":{\"level\":300}}", "integer out of range", "level");
    expect_error<Everything>("{\"inner\":{\"zzz\":1}}", "unknown key", "zzz");
    expect_error<Point>("[1,2]", "expected '{'", "");
    expect_error<Point>("\"text\"", "expected '{'", "");
    expect_error<Point>("{\"\\u0078\":1}", "unknown key", "\\u0078");
}

fn test_decode_syntax_errors() {
    expect_syntax<Point>("{\"x\":1,", "expected a key");
    expect_syntax<Point>("{\"x\":1} x", "trailing input");
    expect_syntax<Point>("{\"x\":1,\"y\":2}}", "trailing input");
    expect_syntax<Point>("", "expected a value");
    expect_syntax<Point>("{\"x\" 1}", "expected ':'");
    expect_syntax<Title>("{\"title\":\"a\nb\"}", "bad string");
    expect_syntax<Title>("{\"title\":\"\xff\"}", "invalid UTF-8");
    expect_syntax<Title>("{\"title\":\"\xc3\"}", "invalid UTF-8");
}

// The stdlib json namespace is usable from a program that imports only the package.
fn test_stdlib_reader() {
    let r = json::reader("[7]");
    assert(json::peek(r) == '[');
}

fn test_empty_object() {
    let point, res = web::json_decode<Point>("  {  }  ");
    assert(res.ok && point.x == 0 && point.y == 0);
    assert(res.present == 0);
}

fn test_encode_limits_and_nesting() {
    let text = encode(Series { id: 2, values: [] });
    assert(text == "{\"id\":2,\"values\":[]}");
    let limited, res = web::json_decode<Limits>("{\"limited\":[1,2,3,4],\"labels\":[\"x\",\"yz\"]}");
    assert(res.ok && limited.limited == [1, 2, 3, 4] && limited.labels[1] == "yz");
}

fn test_json_key_encode() {
    // The renamed key is written, the skipped field is not.
    let text = encode(Renamed { id: 1, completed: true, secret: 9 });
    assert(text == "{\"id\":1,\"done\":true}");
    // Nested: the struct's own hooks apply inside the parent object.
    let nested = encode(Wrapper { label: "w", item: Renamed { id: 3, completed: false, secret: 0 } });
    assert(nested == "{\"label\":\"w\",\"item\":{\"id\":3,\"done\":false}}");
    assert(web::check_json_keys<Renamed>());
    var report: u8[>..] = [];
    assert(web::json_key_report<Renamed>(report) && report.len == 0);
}

fn test_json_key_decode() {
    let back, res = web::json_decode<Renamed>("{\"id\":2,\"done\":true}");
    assert(res.ok && back.id == 2 && back.completed && back.secret == 0);
    // present keeps field order (id = bit 0, completed = bit 1, secret = bit 2) and has<T>
    // takes the declared name, not the JSON one.
    assert(res.present == 3);
    assert(web::has<Renamed>(res, "completed") && web::has<Renamed>(res, "id"));
    assert(!web::has<Renamed>(res, "secret"));
    // The original name is unknown once renamed, and a skipped field is unknown on the wire.
    expect_error<Renamed>("{\"completed\":true}", "unknown key", "completed");
    expect_error<Renamed>("{\"secret\":1}", "unknown key", "secret");
    expect_error<Renamed>("{\"done\":true,\"done\":false}", "duplicate key", "done");
    expect_error<Renamed>("{\"done\":1}", "expected true or false", "done");
    // Nested: the renamed key is read inside the parent, and the error names the JSON key.
    let outer, outer_res = web::json_decode<Wrapper>("{\"label\":\"x\",\"item\":{\"id\":4,\"done\":true}}");
    assert(outer_res.ok && outer.item.id == 4 && outer.item.completed);
    expect_error<Wrapper>("{\"item\":{\"completed\":true}}", "unknown key", "completed");
}

fn test_json_key_duplicates() {
    assert(!web::check_json_keys<Clash>());
    var report: u8[>..] = [];
    assert(!web::json_key_report<Clash>(report));
    assert(report == "duplicate JSON key: same");
    // At use, encode fails and leaves the output unchanged; decode reports a schema error.
    var out: u8[>..] = [];
    out.append("keep;");
    assert(!web::json_encode(out, Clash { a: true, b: false }));
    assert(out == "keep;");
    let back, res = web::json_decode<Clash>("{\"same\":true}");
    assert(!res.ok && !res.syntax);
    assert(res.error == "duplicate JSON key name");
}

// Escapes that decode to bytes which are not UTF-8 are refused at decode time, so a text field
// never holds them. A valid surrogate pair decodes to one 4-byte code point.
fn test_surrogates() {
    expect_error<Title>("{\"title\":\"\\uD800\",\"done\":true}", "invalid UTF-8 in string", "title");
    expect_error<Title>("{\"title\":\"a\\uDC00b\",\"done\":true}", "invalid UTF-8 in string", "title");
    expect_error<Title>("{\"title\":\"\\uD83D x\",\"done\":true}", "invalid UTF-8 in string", "title");
    let back, res = web::json_decode<Title>("{\"title\":\"\\uD83D\\uDE00\",\"done\":false}");
    assert(res.ok && back.title == "\xf0\x9f\x98\x80");
    assert(encode(back) == "{\"title\":\"\xf0\x9f\x98\x80\",\"done\":false}");
}

fn main() {
    test_surrogates();
    test_json_key_encode();
    test_json_key_decode();
    test_json_key_duplicates();
    test_encode_compact();
    test_encode_scalars();
    test_escaping();
    test_unicode();
    test_floats();
    test_encode_failures();
    test_grow_array_encode();
    test_roundtrip_everything();
    test_defaults_and_present();
    test_decode_errors();
    test_decode_syntax_errors();
    test_empty_object();
    test_stdlib_reader();
    test_encode_limits_and_nesting();
    print("JSON codec tests passed: encode, decode, errors, defaults, capacities");
}
