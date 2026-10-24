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
    var scratch = web::AppScratch { .. };
    var c = web::new_ctx(web::Request { method: "GET", target: "/", body: "", raw_headers: "Host: x\r\n" }, shared, scratch);
    var page = sample();
    web::html_template<Page>(c, "<p>{{title}}</p>", page);
    assert(c.written && c.response.status == web::HTTP_OK);
    assert(c.response.content_type == web::CONTENT_TYPE_HTML);
    assert(web::body_of(c.response) == "<p>&lt;b&gt;&quot;Tom&quot; &amp; &#39;Jerry&#39;&lt;/b&gt;</p>");

    var failed_response = web::response();
    var failed_scratch = web::AppScratch { .. };
    var failed = web::new_ctx(web::Request { method: "GET", target: "/", body: "", raw_headers: "Host: x\r\n" }, failed_response, failed_scratch);
    web::html_template<Page>(failed, "{{nope}}", page);
    assert(failed.response.status == web::HTTP_INTERNAL_SERVER_ERROR);
    assert(find(web::body_of(failed.response), "\"code\":\"template_error\"") >= 0);
    assert(find(web::body_of(failed.response), "unknown field: nope") >= 0);
}

// --- composition: layouts, blocks, partials, nested structs, loop helpers ------------------

// A nested struct field. Registration (api.md, Templates): refuse printing and each, and let
// dotted names reach its fields.
struct Author { name: u8[..16], admin: bool }
struct Post { title: u8[..32], author: Author, featured: bool, items: Item[..4] }
struct Shell { meta: web::PageMeta, body: u8[..16] }

fn web::tpl_show(out: u8[>..]&, v: Author&, escape: bool) -> bool { return false; }
fn web::tpl_each_value(out: u8[>..]&, body: const u8[:], v: Author&, checking: bool, depth: i64, env: web::TplEnv&, count: i64&, result: web::TemplateResult&) -> bool {
    return web::tpl_fail(result, "each needs an array of structs");
}
fn web::tpl_show_sub(out: u8[>..]&, v: Author&, tail: const u8[:], escape: bool, result: web::TemplateResult&) -> bool {
    return web::tpl_field(out, v, tail, escape, result);
}
fn web::tpl_flag_sub(data: Author&, tail: const u8[:], flag: bool&, result: web::TemplateResult&) -> bool {
    return web::tpl_flag(data, tail, flag, result);
}

fn sample_post() -> Post {
    var post = Post { title: "Hello", author: Author { name: "ann<", admin: true }, featured: false, .. };
    post.items.push(Item { name: "a<", done: true, qty: 1 });
    post.items.push(Item { name: "b", done: false, qty: 2 });
    return post;
}

// Renders with a registry (or an empty one) and requires exactly want.
fn expect_with<T>(template: const u8[:], data: T&, partials: web::Templates&, want: const u8[:]) {
    var out: u8[>..] = [];
    let ok, result = web::render_result<T>(out, template, data, partials);
    assert(ok);
    assert(out[..] == want);
}

// Renders and requires the reason.
fn expect_fail_with<T>(template: const u8[:], data: T&, partials: web::Templates&, reason: const u8[:]) {
    var out: u8[>..] = [];
    let ok, result = web::render_result<T>(out, template, data, partials);
    assert(!ok);
    assert(out.len == 0);
    assert(result.error[..] == reason);
}

// Renders a page into a layout and requires the bytes.
fn expect_layout(layout: const u8[:], page: const u8[:], data: Post&, partials: web::Templates&, want: const u8[:]) {
    var out: u8[>..] = [];
    let ok, result = web::render_layout_result<Post>(out, layout, page, data, partials);
    assert(ok);
    assert(out[..] == want);
}

fn test_layouts() {
    var post = sample_post();
    var none = web::templates();
    // Page blocks fill the layout's slots; the default shows when the page does not define one.
    expect_layout("<t>{{$title}}Site{{/title}}</t>[{{> content}}]", "{{$title}}{{title}}{{/title}}body {{title}}", post, none, "<t>Hello</t>[body Hello]");
    expect_layout("<t>{{$title}}Site{{/title}}</t>[{{> content}}]", "plain", post, none, "<t>Site</t>[plain]");
    // Blocks defined in the page are not shown in its body; a block can sit inside a section.
    expect_layout("{{> content}}", "a{{$x}}hidden{{/x}}b", post, none, "ab");
    expect_layout("{{$head}}H{{/head}}|{{$scripts}}S{{/scripts}}|{{> content}}", "{{$scripts}}X{{/scripts}}body", post, none, "H|X|body");

    // A layout's partials and page content.
    var views = web::templates();
    assert(web::add_template(views, "nav", "<nav>{{title}}</nav>"));
    expect_layout("{{> nav}}|{{> content}}", "p", post, views, "<nav>Hello</nav>|p");

    // The same block twice, and content outside a layout, are errors.
    var out: u8[>..] = [];
    let twice_ok, twice = web::render_layout_result<Post>(out, "{{> content}}", "{{$x}}a{{/x}}{{$x}}b{{/x}}", post, none);
    assert(!twice_ok && twice.error[..] == "block defined twice: x");
    expect_fail_with("{{> content}}", post, none, "content is only in a layout");
    expect_fail_with("{{$x}}{{nope}}{{/x}}", post, none, "unknown field: nope");
}

fn test_partials() {
    var post = sample_post();
    var views = web::templates();
    assert(web::add_template(views, "nav", "<nav>{{title}}</nav>"));
    assert(web::add_template(views, "loop", "x{{> loop}}"));
    assert(!web::add_template(views, "nav", "again"));
    assert(!web::add_template(views, "content", "c"));
    assert(!web::add_template(views, "bad name", "c"));
    assert(!web::add_template(views, "bad}", "c"));
    let invalid: u8[1] = [0xff];
    assert(!web::add_template(views, "nul", invalid[..]));
    assert(web::add_template(views, "item", "{{@index}}:{{name}}"));
    assert(views.count == 3);

    expect_with<Post>("a{{> nav}}b", post, views, "a<nav>Hello</nav>b");
    // Partials see the loop they are in.
    expect_with<Post>("{{#each items}}[{{> item}}]{{/each}}", post, views, "[0:a&lt;][1:b]");
    // A partial that includes itself fails; the depth limit still bounds longer chains.
    expect_fail_with("{{> loop}}", post, views, "partial includes itself: loop");
    expect_fail_with("{{> missing}}", post, views, "unknown partial: missing");

    var chain = web::templates();
    assert(web::add_template(chain, "c1", "{{> c2}}"));
    assert(web::add_template(chain, "c2", "{{> c3}}"));
    assert(web::add_template(chain, "c3", "{{> c4}}"));
    assert(web::add_template(chain, "c4", "{{> c5}}"));
    assert(web::add_template(chain, "c5", "{{> c6}}"));
    assert(web::add_template(chain, "c6", "{{> c7}}"));
    assert(web::add_template(chain, "c7", "{{> c8}}"));
    assert(web::add_template(chain, "c8", "end"));
    assert(web::add_template(chain, "c9", "{{> c1}}"));
    expect_with<Post>("{{> c1}}", post, chain, "end");
    expect_fail_with("{{> c9}}", post, chain, "partials are nested too deeply");
}

fn test_check_layouts() {
    var views = web::templates();
    assert(web::add_template(views, "nav", "<nav>{{title}}</nav>"));
    let good, message = web::check_template<Post>("{{> nav}}{{> content}}", "{{$x}}{{title}}{{/x}}", views);
    assert(good && message.len == 0);
    let missing_ok, missing = web::check_template<Post>("{{> nope}}{{> content}}", "page", views);
    assert(!missing_ok && missing[..] == "layout: unknown partial: nope");
    let page_ok, page_message = web::check_template<Post>("{{> content}}", "{{nope}}", views);
    assert(!page_ok && page_message[..] == "page: unknown field: nope");

    // A partial is checked where a template uses it: an unused one is not, a used one that
    // includes itself is refused, and content is not allowed in a plain template.
    var broken = web::templates();
    assert(web::add_template(broken, "loop", "x{{> loop}}"));
    let unused_ok, unused_message = web::check_template<Post>("plain", broken);
    assert(unused_ok && unused_message.len == 0);
    let loop_ok, loop_message = web::check_template<Post>("{{> loop}}", broken);
    assert(!loop_ok && loop_message[..] == "partial includes itself: loop");
    let content_ok, content_message = web::check_template<Post>("{{> content}}");
    assert(!content_ok && content_message[..] == "content is only in a layout");
    let plain_ok, plain_message = web::check_template<Post>("{{> nav}}", views);
    assert(plain_ok && plain_message.len == 0);
}

fn test_loop_helpers() {
    var page = sample();
    var none = web::templates();
    var empty = empty_page();
    expect_with<Page>("{{#each items}}{{@index}}{{#@first}}F{{/@first}}{{#@last}}L{{/@last}}[{{name}}]{{/each}}", page, none, "0F[a&lt;]1L[b]");
    expect_with<Page>("{{#each items}}{{@count}}{{/each}}", page, none, "22");
    expect_with<Page>("{{#each items}}{{^@first}}, {{/@first}}{{name}}{{/each}}", page, none, "a&lt;, b");
    expect_with<Page>("{{#each items}}{{name}}{{else}}none{{/each}}", page, none, "a&lt;b");
    expect_with<Page>("{{#each items}}{{name}}{{else}}none{{/each}}", empty, none, "none");
    expect_with<Page>("[{{#each items}}x{{else}}]{{/each}}", empty, none, "[]");

    expect_fail_with("{{@index}}", page, none, "loop values are only inside each");
    expect_fail_with("{{else}}", page, none, "else is only inside each");
    expect_fail_with("{{#each items}}{{@nope}}{{/each}}", page, none, "unknown loop value: nope");
}

fn test_dotted_paths() {
    var post = sample_post();
    var none = web::templates();
    expect_with<Post>("{{author.name}}", post, none, "ann&lt;");
    expect_with<Post>("{{#author.admin}}A{{/author.admin}}{{^author.admin}}N{{/author.admin}}", post, none, "A");
    expect_with<Post>("{{#author.admin}}A{{/author.admin}}{{^featured}}F{{/featured}}", post, none, "AF");
    expect_fail_with("{{author.nope}}", post, none, "unknown field: nope");
    expect_fail_with("{{title.x}}", post, none, "no registered struct for: x");
    expect_fail_with("{{nope.x}}", post, none, "unknown field: nope");
    expect_fail_with("{{author}}", post, none, "value cannot be printed: author");
    expect_fail_with("{{#author.name}}x{{/author.name}}", post, none, "section needs a bool field: name");

    let good, message = web::check_template<Post>("{{author.name}}{{#author.admin}}x{{/author.admin}}");
    assert(good && message.len == 0);
    let bad, bad_message = web::check_template<Post>("{{author.nope}}");
    assert(!bad && bad_message[..] == "unknown field: nope");

    // PageMeta is registered in page.goose: dotted values and flags work through the struct field.
    var shell = Shell { .. };
    shell.meta.title.append("Home");
    shell.meta.path.append("/");
    shell.meta.has_flash = true;
    shell.meta.flash_message.append("Saved");
    expect_with<Shell>("{{meta.title}}|{{meta.path}}|{{#meta.has_flash}}[{{meta.flash_message}}]{{/meta.has_flash}}|{{meta.csrf_token}}", shell, none, "Home|/|[Saved]|");
    shell.meta.has_flash = false;
    expect_with<Shell>("{{#meta.has_flash}}x{{/meta.has_flash}}{{^meta.has_flash}}none{{/meta.has_flash}}", shell, none, "none");
}

fn test_blocks_in_plain_render() {
    var post = sample_post();
    var none = web::templates();
    // Outside a layout a block shows its body in place.
    expect_with<Post>("a{{$x}}in{{/x}}b", post, none, "ainb");
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
    test_layouts();
    test_partials();
    test_check_layouts();
    test_loop_helpers();
    test_dotted_paths();
    test_blocks_in_plain_render();
    print("App template tests passed: escaping, raw values, sections, each, comments, error classes, check_template, XSS payloads, html_template, layouts, blocks, partials, cycles and depth, each helpers, dotted paths");
}
