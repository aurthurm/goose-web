// Static path resolution fuzzing: random and hostile request paths against tests/fixtures/static.
// Whatever resolves (HTTP_OK) must be a regular file under the root, with no traversal or hidden
// segment; everything else must be a 400 or a 404. Reproducible splitmix64 seeds, recorded here:
// 1, 42, 20261022 and 3735928559, 4096 inputs each. Run from the repository root.
import goose_web from "../..";
import std;

const STATIC_ROOT = "tests/fixtures/static";
// Bytes in STATIC_ROOT.
const STATIC_ROOT_BYTES = 21;

var calls: i64 = 0;
var served: i64 = 0;

fn check(rel: const u8[:]) {
    calls += 1;
    var full: u8[>..] = [];
    let status = web::static_resolve(rel, STATIC_ROOT, full);
    assert(status == web::HTTP_OK || status == web::HTTP_BAD_REQUEST || status == web::HTTP_NOT_FOUND);
    if status != web::HTTP_OK { return; }
    served += 1;
    let path = full[..];
    assert(path.len > STATIC_ROOT_BYTES + 1);
    assert(path[..STATIC_ROOT_BYTES] == STATIC_ROOT);
    assert(path[STATIC_ROOT_BYTES] == '/');
    // No segment is "." or "..", and no segment after the root is hidden.
    assert(find(path, "/../") < 0 && find(path, "/./") < 0);
    let below = path[STATIC_ROOT_BYTES + 1..];
    assert(below.len > 0 && below[0] != '.');
    assert(find(below, "/.") < 0);
    assert(web::file_kind(path) == web::FILE_KIND_REGULAR);
}

// Segments a path can be built from: plain names, traversal in every spelling, hidden names,
// encoded separators and NULs, and random bytes.
fn segment(random: rng&, out: u8[>..]&) {
    let segments = ["index.html", "docs", "hello.txt", "style.css", "..", ".", "%2e%2e", "%2E%2e", "%2e",
                    "%2e%2E", "%2F", "%2f", "%5C", "%5c", "%00", "%0a", "%7f", "%", "%g1", "%2", ".hidden",
                    "...", "a%20b", "%2e%2e%2f", "\\", "\x00", "\x7f", "\xc3\xa9", "", "index", "%3f",
                    "%23", "x y", "%ff"];
    out.append(segments[rand_int(random, segments.len)]);
}

fn build(random: rng&, out: u8[>..]&) {
    out.clear();
    if rand_int(random, 8) == 0 {
        // Random bytes, including separators and controls, behind a slash.
        out.push('/');
        let length = rand_int(random, 40);
        for i in length { out.push(rand_int(random, 256) as u8); }
        return;
    }
    let parts = rand_int(random, 6);
    for part in parts {
        let separator = rand_int(random, 5);
        if separator == 0 { out.push('/'); }
        if separator == 1 { out.push('/'); out.push('/'); }
        if separator == 2 { out.push('\\'); }
        segment(random, out);
        out.push('/');
    }
}

fn fuzz(seed: u64) {
    var random = rng { s: seed };
    for iteration in 4096 {
        var rel: u8[>..] = [];
        build(random, rel);
        check(rel[..]);
    }
}

// Fixed cases: each must refuse or serve exactly as documented in docs/api.md.
fn named_cases() {
    var full: u8[>..] = [];
    assert(web::static_resolve("index.html", STATIC_ROOT, full) == web::HTTP_OK);
    full.clear();
    assert(web::static_resolve("", STATIC_ROOT, full) == web::HTTP_OK);
    full.clear();
    assert(web::static_resolve("docs/", STATIC_ROOT, full) == web::HTTP_OK);
    full.clear();
    assert(web::static_resolve("../tests/fixtures/static/index.html", STATIC_ROOT, full) == web::HTTP_BAD_REQUEST);
    full.clear();
    assert(web::static_resolve("%2e%2e/index.html", STATIC_ROOT, full) == web::HTTP_BAD_REQUEST);
    full.clear();
    assert(web::static_resolve("docs%2Findex.html", STATIC_ROOT, full) == web::HTTP_BAD_REQUEST);
    full.clear();
    assert(web::static_resolve("%5c..%5cindex.html", STATIC_ROOT, full) == web::HTTP_BAD_REQUEST);
    full.clear();
    assert(web::static_resolve("a%00b", STATIC_ROOT, full) == web::HTTP_BAD_REQUEST);
    full.clear();
    assert(web::static_resolve(".git/config", STATIC_ROOT, full) == web::HTTP_NOT_FOUND);
    full.clear();
    assert(web::static_resolve("missing.txt", STATIC_ROOT, full) == web::HTTP_NOT_FOUND);
}

fn main() {
    named_cases();
    fuzz(1);
    fuzz(42);
    fuzz(20261022);
    fuzz(3735928559);
    print("Static path fuzz tests passed: ", calls, " paths, ", served, " served, all inside the root; splitmix64 seeds 1,42,20261022,3735928559");
}
