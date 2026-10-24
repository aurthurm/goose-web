# Pages example

A server-rendered todo list: `GET /` renders the page and `POST /todos` adds a todo from a
form and redirects back with 303. It shows the template and form APIs together; the JSON
todo API is in [examples/basic](../basic/README.md).

Files:

- `server.goose`: routes, the form binding, and the startup template check.
- `views/list.html`: the page, embedded with `embed_file("views/list.html")`.

Build and run:

```sh
mkdir -p build
goose build examples/pages/server.goose -o build/pages
./build/pages 8080
```

Try it:

```sh
curl http://127.0.0.1:8080/
curl -i -H 'Content-Type: application/x-www-form-urlencoded' \
  --data 'title=<b>Buy+milk</b>' http://127.0.0.1:8080/todos
curl http://127.0.0.1:8080/
```

The second request returns `303 See Other` with `Location: /`. The list shows the title
escaped, so the markup appears as text. An empty title gets 422 `title_required`, and a
JSON body gets 415.

Template features used by `views/list.html`:

- `{{title}}` and `{{count}}`: escaped strings and integers.
- `{{#empty}}` / `{{^empty}}`: a bool section for the empty state.
- `{{#each todos}}`: one `<li>` per todo; `{{#done}}` inside the loop reads the todo's own flag.
- `{{! ... }}`: a comment that is dropped from the output.

`main` calls `check_template<ListPage>` before the server starts, so a template that names a
missing field fails at startup with the reason, not on the first request. The list holds 32
todos in memory; a full list answers 409 `list_full`. Restarting the server clears it.

To work on the page with reload, run it through the development server. It rebuilds and restarts
on each save, and the browser reloads (a compile error appears over the page):

```sh
python3 scripts/dev.py examples/pages/server.goose --port 8080
```

`web::live_reload(c)` in `server.goose` adds the reload script only under that command; a plain
`./build/pages` start is unchanged. See [development server](../../docs/api.md#development-server-and-live-reload).
