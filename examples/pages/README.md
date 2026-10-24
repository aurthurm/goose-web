# Pages example

A server-rendered todo app with a shared layout. The list filters by `?filter=`, and each todo has
a detail page, an edit form with validation, a toggle and a delete. Every write is a form POST
with a CSRF token and redirects with a flash message, which the next page shows once. Unknown
addresses get a 404 page rendered with the same layout. The JSON todo API is in
[examples/basic](../basic/README.md).

Files:

- `server.goose`: routes, the page data structs, the form bindings, the session and CSRF
  middleware, and the startup checks.
- `views/layout.html`: the shared layout. It places the page body with `{{> content}}`, fills
  the `{{$head}}` slot from the page, and shows the flash message.
- `views/_nav.html`, `views/_footer.html`, `views/_todo_row.html`: partials, registered in `main`
  with `web::add_template`. The row partial renders once per todo inside `{{#each}}`.
- `views/list.html`, `detail.html`, `edit.html`, `not_found.html`: the pages.
- `public/style.css`: the styles, served by `c.static_files("/static", ...)`.

Build and run:

```sh
mkdir -p build
goose build examples/pages/server.goose -o build/pages
./build/pages 8080
```

Open `http://127.0.0.1:8080/` in a browser, or try it from the shell. The CSRF token comes from
the page and the cookie that goes with it:

```sh
curl -c jar -b jar -s http://127.0.0.1:8080/ > list.html
TOKEN=$(sed -n 's/.*name="csrf_token" value="\([^"]*\)".*/\1/p' list.html | head -1)
curl -c jar -b jar -i --data "csrf_token=$TOKEN&title=Buy+milk" http://127.0.0.1:8080/todos
curl -c jar -b jar -s http://127.0.0.1:8080/ | grep 'flash'   # the flash shows once
curl -i http://127.0.0.1:8080/todos/99                        # 404 page with the layout
```

The write returns `303 See Other` with `Location: /`. A POST without the token gets 403
`csrf_failed`. An empty title is refused with a flash message, and an edit with only spaces
comes back as 422 with the typed value and the error.

Template features used here:

- `views/layout.html`: `{{meta.title}}`, a dotted name into the `PageMeta` field. `{{#meta.has_flash}}`
  is a section over a dotted flag. `{{$head}}{{/head}}` is a slot with an empty default; the detail
  page defines it to add `noindex`. `{{> nav}}`, `{{> content}}` and `{{> footer}}` place the rest.
- `views/list.html`: `{{#each todos}}...{{else}}...{{/each}}` shows the empty state. The row partial
  reads `{{id}}`, `{{title}}`, `{{#done}}` and `{{@index}}` from the element.
- `views/edit.html`: `value="{{title}}"` keeps the typed value on a validation failure.
- `views/_nav.html`: `{{#nav_todos}}` marks the active link. Each page struct sets it.

`main` checks every page with its layout and partials before the server starts
(`check_template<T>(layout, page, views)`), so a template mistake stops the program at startup with
the reason.

Pages and their data are in `server.goose`; state lives in memory and resets when the server
restarts. The session cookie carries the flash message, and the demo `SECRET` must be replaced
for a real deployment.

## Develop with live reload

```sh
python3 scripts/dev.py examples/pages/server.goose --port 8080
```

`dev.py` rebuilds on every change to the Goose sources, views or CSS, restarts the server, and reloads the
browser; a failed build keeps the old server running and shows the compiler error in the page.
