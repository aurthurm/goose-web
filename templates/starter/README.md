# PROJECT_NAME

A starter Goose Web application: JSON routes, typed request bodies and query strings, request
middleware, an HTML page from a template, and a generated OpenAPI 3.1 document.

## Requirements

- The Goose compiler (`goose` on PATH, or set `GOOSE=/path/to/goose`). Goose Web is fetched by
  the compiler on first build; no other package manager is involved.
- A C compiler (`cc`, `gcc` or `clang`) and `git` for the fetch, as Goose needs them.

## Run it

```sh
goose run server.goose -- 8080                  # compile in process and serve on port 8080
goose build server.goose -o build/server        # or build an executable once
./build/server --port 8080
```

Then open <http://127.0.0.1:8080/> (the page), <http://127.0.0.1:8080/docs> (the API reference)
or call the API:

```sh
curl http://127.0.0.1:8080/health
curl -H 'Content-Type: application/json' --data '{"text":"hello"}' http://127.0.0.1:8080/notes
curl 'http://127.0.0.1:8080/notes?limit=5'
```

Ctrl+C stops the server; it drains open connections for a few seconds first.

## Develop with reload

```sh
python3 scripts/dev.py server.goose                  # serves on 8080, reload endpoint on 8081
python3 scripts/dev.py server.goose --port 9000      # other ports; --reload-port sets the second
```

The script builds the server, runs it, and watches the project for changes. Saving a file rebuilds
and restarts the server, and the open page reloads. A build error is shown in the browser over the
page, and the previous server keeps running until the next successful build. `--release` builds
optimized code instead, and arguments after `--` go to the program. The page gets its reload script
only while `scripts/dev.py` runs: `web::live_reload(c)` in `server.goose` injects it, and does nothing
when `GOOSE_WEB_LIVE_RELOAD` is unset. Linux uses inotify; the script polls elsewhere.
Details are in [development server](https://github.com/aurthurm/goose-web/blob/main/docs/api.md#development-server-and-live-reload).

## Test it

```sh
python3 test.py
```

The script builds `server.goose`, starts it on a free port, checks every route, and stops it. It
prints one line per check and exits nonzero on the first failure.

## Layout

```text
server.goose          routes, middleware, OpenAPI, main
views/home.html       the page template, checked at startup and embedded at compile time
test.py               end-to-end checks (standard library only)
```

## The import

`server.goose` declares the framework in its first line:

```goose
import goose_web from "GOOSE_WEB_SOURCE";
```

The script writes the source it was given here. By default it is `aurthurm/goose-web@v0.6.0`, a
fetched package pinned to a release tag. The compiler downloads it into `~/.goose` on
the first build. Other forms (a local checkout, a commit, a branch) are described in the
[getting started guide](https://aurthurm.github.io/goose-web/getting-started.html). Only the root
file declares packages, so this line is the only place to change the version.

## Next steps

- [Routing and requests](https://aurthurm.github.io/goose-web/http.html) for groups, parameters, bodies and forms.
- [Templates, sessions, CSRF, SQLite and SSE](https://aurthurm.github.io/goose-web/features.html).
- [API reference](https://github.com/aurthurm/goose-web/blob/main/docs/api.md) for every call.
