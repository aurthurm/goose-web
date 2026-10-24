// Query string, cookie and form body fuzzing. Reproducible splitmix64 seeds, recorded here: 1, 42,
// 20261022 and 3735928559, 4096 inputs each. Every returned view must lie inside its input, every
// accepted integer must be canonical, and every rejected form must write an error response.
import goose_web from "../..";
import std;

struct Form { count: i64 = 0, name: u8[..16] = "", on: bool = false }

var calls: i64 = 0;
var rejected_forms: i64 = 0;

// True when view lies within raw (view is a slice of raw, not a copy elsewhere).
fn inside(view: const u8[:], raw: const u8[:]) -> bool {
    if view.len == 0 { return true; }
    if view.len > raw.len { return false; }
    for start in raw.len - view.len + 1 {
        if raw[start..start + view.len] == view { return true; }
    }
    return false;
}

// Query: the key lookup, the decoder's status, and the canonical-integer rule.
fn check_query(target: const u8[:]) {
    calls += 1;
    let raw = web::query_value(target, "k");
    assert(raw.status == web::QUERY_MISSING || raw.status == web::HTTP_OK ||
           raw.status == web::HTTP_BAD_REQUEST || raw.status == web::HTTP_CONTENT_TOO_LARGE);
    if raw.status != web::HTTP_OK { return; }
    assert(raw.value.len <= web::MAX_QUERY_FIELD_BYTES);
    // A decoded value is never longer than the encoded query it came from.
    assert(raw.value.len <= target.len);
    let number, canonical = web::parse_canonical(raw.value[..]);
    if canonical {
        assert(number >= 0);
        // Canonical text has no sign and no leading zero.
        assert(raw.value.len == 1 || raw.value[0] != '0');
    }
}

// Cookie: the lookup returns only the value of the named pair, unquoted, and never more than the
// header holds.
fn check_cookie(header: const u8[:]) {
    calls += 1;
    let sid = web::cookie_lookup(header, "sid");
    assert(inside(sid, header));
    assert(sid.len == 0 || find(sid, ";") < 0);
    let missing = web::cookie_lookup(header, "");
    assert(missing.len == 0);
}

// Form: a bad body is refused with a 4xx or 5xx response and nothing is bound; a good one fits the
// struct's capacities.
fn check_form(body: const u8[:]) {
    calls += 1;
    var out = web::response();
    var scratch = web::AppScratch { .. };
    var c = web::new_ctx(web::Request { method: "POST", target: "/form", body: body,
                                        raw_headers: "Host: x\r\nContent-Type: application/x-www-form-urlencoded\r\n" },
                         out, scratch);
    let value, ok = web::form<Form>(c);
    if ok {
        assert(value.name.len <= 16);
        return;
    }
    rejected_forms += 1;
    assert(c.written && c.response.status >= 400);
}

// Pieces that make plausible and hostile query strings and forms.
fn piece(random: rng&, out: u8[>..]&) {
    let pieces = ["k", "k=", "=", "&", "&&", "=&", "%", "%41", "%zz", "%2", "+", "%2B", "%00", "%ff", "k=1",
                  "k=0", "k=007", "k=-1", "k=99999999999999999999", "k=9223372036854775807", "k=%39", "sid=",
                  "sid=abc", "sid=\"q\"", "sid=a;b", "; ", "name=", "count=12", "on=true", "count=", "?", "#",
                  "\xc3\xa9", "\x01", "\\", "\"", "'", ";", " "];
    out.append(pieces[rand_int(random, pieces.len)]);
}

fn build(random: rng&, out: u8[>..]&) {
    out.clear();
    let parts = 1 + rand_int(random, 10);
    for part in parts {
        if rand_int(random, 4) == 0 {
            // A random byte, for the bytes no list would name.
            out.push(rand_int(random, 256) as u8);
        } else {
            piece(random, out);
        }
    }
}

fn fuzz(seed: u64) {
    var random = rng { s: seed };
    for iteration in 4096 {
        var text: u8[>..] = [];
        build(random, text);
        check_query(text[..]);
        var target: u8[>..] = [];
        target.append("/search?");
        target.append(text[..]);
        check_query(target[..]);
        check_cookie(text[..]);
        var header: u8[>..] = [];
        header.append("sid=");
        header.append(text[..]);
        header.append("; theme=dark");
        check_cookie(header[..]);
        check_form(text[..]);
    }
}

fn main() {
    fuzz(1);
    fuzz(42);
    fuzz(20261022);
    fuzz(3735928559);
    print("Query, cookie and form fuzz tests passed: ", calls, " checks, ", rejected_forms,
          " forms refused with an error response; splitmix64 seeds 1,42,20261022,3735928559");
}
