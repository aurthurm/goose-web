# Project commands and build files

Goose Web uses the Goose compiler for language and package work, Python for project commands,
and an optional Makefile for short aliases. These commands ship with this checkout and with
starters generated from it; they are not a globally installed `goose-web` executable.

## Which file controls what?

| File | Purpose |
| --- | --- |
| `server.goose` | Application entry point; declares package sources with `import ... from ...` |
| `goose_web.goose` | Framework package facade; exports its modules |
| `goose_web.build` | Framework's native C sources, linked libraries and main-thread restriction |
| `db/goose_web_db.build` | Optional SQLite package's native build settings |
| `manage.py` | Development, build, test and CI command orchestration |
| `Makefile` | Optional aliases for the same project commands |
| `.github/workflows/ci.yml` | Framework CI: pinned compiler, GCC/Clang, `manage.py ci` |

There is no framework TOML manifest. A TOML file alone would have no effect: the current compiler
reads dependency sources from the root `.goose` file and native settings from `.build` sidecars.
You do not need a sidecar in an application that only imports packages. Add `server.build` beside
`server.goose` if the application itself has native code. For the compiler package model, see
[upstream packages documentation](https://github.com/aardappel/goose/blob/6ad201219c80b2b8c7cf865cf7bcc01469e1ec5c/docs/packages.md).

## Create a project

From the framework checkout:

```sh
python3 manage.py new my-app ../my-app
cd ../my-app
python3 manage.py check
python3 manage.py dev --port 8080
```

The generator writes a relative import of the current framework checkout by default, and copies
`manage.py`, `Makefile`, the development watcher and a test script. Keep the checkout available:
this is a local dependency, not a vendored copy. An explicit `--source` overrides it; choose a
source that supplies the same APIs as the template. Current templates use APIs absent in
`v0.6.0`, so that older tag is unsuitable. Generation refuses a nonempty destination.

## Everyday commands

Run commands from the project root. `GOOSE` selects the executable (default `goose` on PATH).
`GOOSE_STDLIB`, `GOOSE_CC` and `CC` retain their upstream/test meanings. The command wrapper uses
an absolute `GOOSE_HOME`, defaulting to `build/cache` under the project.

| Command | Effect |
| --- | --- |
| `python3 manage.py toolchain` | Print runtime and discovered compiler/native tools |
| `python3 manage.py fetch` | Fetch package sources declared by the entry point |
| `python3 manage.py check` | Parse and typecheck; do not start a server |
| `python3 manage.py build` | Build `build/server` with Goose runtime debug checks |
| `python3 manage.py build --release` | Optimized `-O2` executable without debug checks |
| `python3 manage.py run -- --port 9000` | Build and run, forwarding arguments after `--` |
| `python3 manage.py dev --port 9000` | Watch, rebuild, restart and serve browser reload events |
| `python3 manage.py test` | Run framework tests, or a generated project's `test.py` |
| `python3 manage.py ci` | Framework: docs then tests; starter: typecheck then test |
| `python3 manage.py docs` | Framework-only local Markdown link/fragment checks |
| `python3 manage.py docs --serve --port 8000` | Serve framework `docs/site` on loopback |

In the framework checkout the default entry is `examples/hello/server.goose`. In a generated
project it is `server.goose`. Select a different root and output without changing configuration:

```sh
python3 manage.py build --entry examples/issue-board/server.goose --output build/issue-board
python3 manage.py run --entry examples/issue-board/server.goose --output build/issue-board -- --port 9000
```

`run` blocks until the program exits. Ctrl+C stops development; production processes should run
the built executable under a service manager. Debug/release here describe Goose build flags, not
separate environments or different application settings.

## Make aliases

Make is optional; it delegates to `manage.py`. There is no second implementation to keep in sync.

```sh
make help
make check
make dev PORT=9000
make build ENTRY=examples/issue-board/server.goose OUTPUT=build/issue-board
make release
make run ARGS="--port 9000"
make test
make ci
make docs
```

`ENTRY`, `OUTPUT`, `PORT`, `GOOSE` and `PYTHON` customize the commands; `ARGS` forwards program
arguments for `run`/`dev`. `make new NAME=my-app DIR=../my-app` invokes the same generator.
There is deliberately no recursive `clean` command that could remove an application's database.

## CI

Use `python3 manage.py ci` or `make ci`; any failed child command produces a nonzero exit status
and stops subsequent steps. Framework CI bootstraps the pinned compiler before invoking it.
A downstream project can use the same command after installing Goose and native dependencies.
It does not install compilers, fetch a new revision, publish artifacts or deploy applications on
its own. See [compiler/CI setup](../ci.md) and [testing](testing.md).
