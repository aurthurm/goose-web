# HTML templates and pages

**Version:** Basic `embed_file`, `html_template` and `check_template` APIs are present in published
`v0.6.0`. Composable layouts, partial registries, `PageMeta` and `html_page` shown below are on
`main`; use the complete current [pages example](../../examples/pages/server.goose) for those APIs.

Use `embed_file` to compile view files into the program. Define a typed data struct per page,
create the partial registry once during startup, and call `check_template` before accepting
requests. Render dynamic values with `{{name}}`, which HTML-escapes strings. Reserve
`{{{name}}}` for content you have deliberately made safe.

```goose
import goose_web from "../goose-web";
import std;
import os;

struct HomePage { meta: web::PageMeta, message: u8[..128] }

fn app(c: web::Ctx&, views: web::Templates&) {
    c.routes() {
        c.get("/") {
            c.html_page(views, embed_file("views/layout.html"), embed_file("views/home.html"),
                HomePage { meta: web::page_meta(c, "Home"), message: "Welcome" });
        };
    };
}

fn main() {
    var registry = web::templates();
    if !web::add_template(registry, "nav", embed_file("views/_nav.html")) { abort("nav partial"); }
    let valid, problem = check_template<HomePage>(embed_file("views/layout.html"), embed_file("views/home.html"), registry);
    if !valid { print(problem[..]); abort("invalid templates"); }
    var config = web::server_config();
    let started = web::run(config) { c => app(c, registry) };
    if !started { abort("server failed"); }
}
```

This function-level sample assumes `views/layout.html`, `views/home.html`, and
`views/_nav.html` exist beside the source. For an immediately buildable application with real
forms, layout and partials, run the [pages example](../../examples/pages/README.md):

```sh
mkdir -p build
goose build examples/pages/server.goose -o build/pages
./build/pages --port 8080
```

For a single template on published `v0.6.0`, use `html_template` without a registry or layout.
This is a complete small app; the embedded file is relative to this source file:

```goose
import goose_web from "../goose-web";
import std;
import os;

struct Home { message: u8[..128] }

fn app(c: web::Ctx&) {
    c.routes() {
        c.get("/") { c.html_template(embed_file("views/home.html"), Home { message: "Welcome" }); };
    };
}
fn main() {
    let valid, problem = check_template<Home>(embed_file("views/home.html"));
    if !valid { print(problem[..]); abort("invalid home template"); }
    var config = web::server_config();
    let started = web::run(config) { c => app(c) };
    if !started { abort("server failed"); }
}
```

The layout can place the page body with `{{> content}}`, provide named block defaults, and include
registered partials with `{{> nav}}`. Pages can override layout blocks. `{{#each rows}}` iterates a
typed array; inside it, names resolve against the row, so copy any outer values (such as a CSRF
token) into each row. `examples/pages` demonstrates layouts, forms and validation.

For forms, wrap the POST route in CSRF middleware and put `c.csrf_token()` into a hidden
`csrf_token` field. The template guide example is only a rendering fragment: it assumes the
session/CSRF middleware, route registration and page files are configured as shown in the
[complete pages example](../../examples/pages/server.goose). `PageMeta` can carry the token,
flash message, path and session user. Flash data requires session middleware and is consumed for
the next page.

Pitfalls: templates must be valid UTF-8; output is bounded; partial recursion and nesting deeper
than eight levels fail. Run `check_template` for every used page/layout pair in `main`; unused
partials are not checked. Template rendering errors become a 500 response. More grammar and
validation details: [Templates API](../api.md#templates), [sessions](../api.md#sessions),
and [CSRF](../api.md#csrf).
