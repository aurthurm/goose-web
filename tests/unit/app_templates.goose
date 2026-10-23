// Template rendering: escaping, raw values, sections, each blocks, comments, every error class,
// check_template, the response helper, and XSS payloads. Form binding is in app_params.
import goose_web from "../..";
import std;

struct Item { name: u8[..32], done: bool, qty: i64 }
struct Page { title: u8[..64], count: i64, ok: bool, empty: bool, items: Item[..4] }

fn sample() -> Page {
    var page = Page { title: "<b>\"Tom\" & 'Jerry'</b>", count: -42, ok: true, empty: false, .. };
    page.items.push(Item { name: "a<", done: true, qty: 1 });
    page.items.push(Item { name: "b", done: false, qty: 2 });
    return page;
}

fn empty_page() -> Page {
    return Page { .. };
}

// Renders and requires success with exactly the expected bytes.
fn expect_render(template: const u8[:], page: Page&, want: const u8[:]) {
    var out: u8[>..] = [];
    let ok, result = web::render_result<Page>(out, template, page);
    assert(ok);
    assert(out[..] == want);
}

// Renders and requires failure: out is unchanged and the reason matches.
fn expect_error(template: const u8[:], page: Page&, reason: const u8[:]) {
    var out: u8[>..] = [];
    let ok, result = web::render_result<Page>(out, template, page);
    assert(!ok);
    assert(out.len == 0);
    assert(result.error[..] == reason);
}

fn test_escaping() {
    var page = sample();
    expect_render("{{title}}", page, "&lt;b&gt;&quot;Tom&quot; &amp; &#39;Jerry&#39;&lt;/b&gt;");
    expect_render("{{ title }}", page, "&lt;b&gt;&quot;Tom&quot; &amp; &#39;Jerry&#39;&lt;/b&gt;");
    expect_render("<p title=\"{{title}}\">", page, "<p title=\"&lt;b&gt;&quot;Tom&quot; &amp; &#39;Jerry&#39;&lt;/b&gt;\">");

    var escaped: u8[>..] = [];
    web::html_escape(escaped, "&<>\"'plain");
    assert(escaped[..] == "&amp;&lt;&gt;&quot;&#39;plain");
}

fn test_raw_and_scalars() {
    var page = sample();
    expect_render("{{{title}}}", page, "<b>\"Tom\" & 'Jerry'</b>");
    expect_render("{{count}} {{ok}}", page, "-42 true");
    var none = empty_page();
    expect_render("{{count}}|{{ok}}|{{title}}|", none, "0|false||");
}

fn test_sections() {
    var page = sample();
    expect_render("{{#ok}}yes{{/ok}}{{^ok}}no{{/ok}}", page, "yes");
    expect_render("{{#empty}}E{{/empty}}{{^empty}}N{{/empty}}", page, "N");
    expect_render("a{{#empty}}hidden{{/empty}}b", page, "ab");
    expect_render("{{#ok}}[{{count}}{{#ok}}!{{/ok}}]{{/ok}}", page, "[-42!]");
    var none = empty_page();
    expect_render("x{{#ok}}y{{/ok}}z", none, "xz");
}

fn test_each() {
    var page = sample();
    expect_render("[{{#each items}}{{name}}{{/each}}]", page, "[a&lt;b]");
    expect_render("{{#each items}}({{name}}{{#done}}+{{/done}}{{^done}}-{{/done}}){{/each}}", page, "(a&lt;+)(b-)");
    expect_render("{{#each items}}{{qty}}{{/each}}", page, "12");
    var none = empty_page();
    expect_render("[{{#each items}}x{{/each}}]", none, "[]");
}

fn test_comments() {
    var page = sample();
    expect_render("a{{! hidden note }}b", page, "ab");
    expect_render("{{! {{# nothing }}", page, "");
}

fn test_error_classes() {
    var page = sample();
    expect_error("{{nope}}", page, "unknown field: nope");
    expect_error("x{{title", page, "unclosed tag");
    expect_error("{{#ok}}x", page, "section is not closed");
    expect_error("{{/ok}}", page, "closing tag without an opening tag");
    expect_error("{{#ok}}x{{/count}}", page, "section closing tag does not match its opening tag");
    expect_error("{{#title}}x{{/title}}", page, "section needs a bool field: title");
    expect_error("{{#each count}}x{{/each}}", page, "each needs an array of structs");
    expect_error("{{#each title}}x{{/each}}", page, "each needs an array of structs");
    expect_error("{{#each items}}{{nope}}{{/each}}", page, "unknown field: nope");
    expect_error("{{}}", page, "empty tag");
    expect_error("{{#nope}}x{{/nope}}", page, "unknown field: nope");
    expect_error("{{items}}", page, "value cannot be printed: items");
    expect_error("{{{items}}}", page, "value cannot be printed: items");

    var bad: u8[2] = ['x', 0xff];
    var out: u8[>..] = [];
    let ok, result = web::render_result<Page>(out, bad[..], page);
    assert(!ok && result.error[..] == "template is not valid UTF-8");
}

fn test_depth_limit() {
    var page = sample();
    var eight: u8[>..] = [];
    for i in 8 { eight.append("{{#ok}}"); }
    eight.append("x");
    for i in 8 { eight.append("{{/ok}}"); }
    var out: u8[>..] = [];
    assert(web::render<Page>(out, eight[..], page));
    assert(out[..] == "x");

    var nine: u8[>..] = [];
    for i in 9 { nine.append("{{#ok}}"); }
    nine.append("x");
    for i in 9 { nine.append("{{/ok}}"); }
    expect_error(nine[..], page, "sections are nested too deeply");
}

fn test_check_template() {
    let good, message = web::check_template<Page>("{{title}}{{#each items}}{{name}}{{#done}}!{{/done}}{{/each}}{{#ok}}x{{/ok}}");
    assert(good && message.len == 0);

    // Validation covers each bodies even when the array is empty.
    let bad_each, each_message = web::check_template<Page>("{{#each items}}{{nope}}{{/each}}");
    assert(!bad_each && each_message[..] == "unknown field: nope");

    let bad_name, name_message = web::check_template<Page>("{{missing}}");
    assert(!bad_name && name_message[..] == "unknown field: missing");

    let bad_section, section_message = web::check_template<Page>("{{#title}}x{{/title}}");
    assert(!bad_section && section_message[..] == "section needs a bool field: title");

    let bad_shape, shape_message = web::check_template<Page>("{{#ok}}x");
    assert(!bad_shape && shape_message[..] == "section is not closed");
}

// Injection payloads never reach the output as markup: no '<' or '"' survives escaping.
fn test_xss_payloads() {
    let payloads: const u8[:][4] = [
        "<script>alert(1)</script>",
        "\"><img src=x onerror=alert(1)>",
        "' onmouseover='alert(1)",
        "&lt;script&gt;",
    ];
    for i in payloads.len {
        var page = empty_page();
        page.title.append(payloads[i]);
        var out: u8[>..] = [];
        assert(web::render<Page>(out, "<h1>{{title}}</h1>", page));
        assert(find(out[..], "<script") < 0 && find(out[..], "<img") < 0);
        assert(find(out[..], "\"") < 0 && find(out[..], "'") < 0);
        assert(find(out[..], "<h1>") == 0);
    }
}

fn test_html_helper() {
    var shared = web::response();
    var c = web::new_ctx(web::Request { method: "GET", target: "/", body: "", raw_headers: "Host: x\r\n" }, shared);
    var page = sample();
    web::html_template<Page>(c, "<p>{{title}}</p>", page);
    assert(c.written && c.response.status == web::HTTP_OK);
    assert(c.response.content_type == web::CONTENT_TYPE_HTML);
    assert(web::body_of(c.response) == "<p>&lt;b&gt;&quot;Tom&quot; &amp; &#39;Jerry&#39;&lt;/b&gt;</p>");

    var failed_response = web::response();
    var failed = web::new_ctx(web::Request { method: "GET", target: "/", body: "", raw_headers: "Host: x\r\n" }, failed_response);
    web::html_template<Page>(failed, "{{nope}}", page);
    assert(failed.response.status == web::HTTP_INTERNAL_SERVER_ERROR);
    assert(find(web::body_of(failed.response), "\"code\":\"template_error\"") >= 0);
    assert(find(web::body_of(failed.response), "unknown field: nope") >= 0);
}

fn main() {
    test_escaping();
    test_raw_and_scalars();
    test_sections();
    test_each();
    test_comments();
    test_error_classes();
    test_depth_limit();
    test_check_template();
    test_xss_payloads();
    test_html_helper();
    print("App template tests passed: escaping, raw values, sections, each, comments, error classes, check_template, XSS payloads, html_template");
}
