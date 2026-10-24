// Template rendering with hostile data. For every input, {{name}} must render exactly as the
// HTML-escaped value (so no markup from data survives), and the rendered page must equal the
// expected page built from html_escape. Reproducible splitmix64 seeds, recorded here: 1, 42,
// 20261022 and 3735928559, 4096 inputs each.
import goose_web from "../..";
import std;

struct Page { title: u8[..96] = "", body: u8[..96] = "", count: i64 = 0, flag: bool = false }

const PAGE = "<h1>{{title}}</h1><p>{{body}}</p><i>{{count}}</i>";

var calls: i64 = 0;

// The page as it must come out, with the escaped values spelled out.
fn expected_page(title: const u8[:], body: const u8[:], count: i64, out: u8[>..]&) {
    out.append("<h1>");
    web::html_escape(out, title);
    out.append("</h1><p>");
    web::html_escape(out, body);
    out.append("</p><i>");
    format(out, count);
    out.append("</i>");
}

fn check(title: const u8[:], body: const u8[:], count: i64) {
    calls += 1;
    var page = Page { .. };
    page.title = title;
    page.body = body;
    page.count = count;
    var rendered: u8[>..] = [];
    let ok, result = web::render_result<Page>(rendered, PAGE, page);
    assert(ok);
    var expected: u8[>..] = [];
    expected_page(title, body, count, expected);
    assert(rendered[..] == expected[..]);
    // Markup from the data never reaches the output as markup: the template itself has six '<'
    // (<h1>, </h1>, <p>, </p>, <i>, </i>) and no value adds one.
    var angles = 0;
    for i in rendered.len {
        if rendered[i] == '<' { angles += 1; }
    }
    assert(angles == 6);
}

// Hostile fragments: markup, quotes, entities, template delimiters and control bytes.
fn piece(random: rng&, out: u8[>..]&) {
    let pieces = ["<", ">", "&", "\"", "'", "`", "&amp;", "&lt;script&gt;", "</h1><script>alert(1)</script>",
                  "\"><img src=x onerror=alert(1)>", "{{title}}", "{{{body}}}", "{{#flag}}", "{{/flag}}",
                  "{{! x }}", "}}", "{{", "\\", "/", "\n", "\t", "\x00", "\x7f", "\xc3\xa9", "\xff", " ", "a"];
    out.append(pieces[rand_int(random, pieces.len)]);
}

fn build(random: rng&, out: u8[>..]&) {
    out.clear();
    let parts = rand_int(random, 12);
    for part in parts {
        if rand_int(random, 3) == 0 {
            out.push(rand_int(random, 256) as u8);
        } else {
            piece(random, out);
        }
    }
    // Keep to the field capacity, so the case is a valid page rather than a capacity error.
    out.resize(if out.len > 96 { 96 } else { out.len });
}

fn fuzz(seed: u64) {
    var random = rng { s: seed };
    for iteration in 4096 {
        var title: u8[>..] = [];
        build(random, title);
        var body: u8[>..] = [];
        build(random, body);
        check(title[..], body[..], rand_int(random, 2000000) - 1000000);
    }
}

// Fixed hostile values that must each survive as text.
fn named_cases() {
    check("<script>alert(1)</script>", "\"><img src=x onerror=alert(1)>", 0);
    check("&amp; &lt; &#39;", "'", 1);
    check("{{title}}", "{{{body}}}", -1);
    check("", "", 0);
}

fn main() {
    named_cases();
    fuzz(1);
    fuzz(42);
    fuzz(20261022);
    fuzz(3735928559);
    print("Template fuzz tests passed: ", calls, " renders; escaped output matches html_escape exactly; splitmix64 seeds 1,42,20261022,3735928559");
}
