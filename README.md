# Goose Web

[![Linux CI](https://github.com/aurthurm/goose-web/actions/workflows/ci.yml/badge.svg)](https://github.com/aurthurm/goose-web/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/tag/aurthurm/goose-web?label=release&sort=semver)](https://github.com/aurthurm/goose-web/tags)

An experimental web framework for the [Goose programming language](https://github.com/aardappel/goose).
Build a native executable with typed routes, JSON validation, SQLite, HTML templates and streaming.
A nonblocking readiness loop handles connections; application handlers run synchronously.

**[Read the documentation](docs/README.md)** · [API reference](docs/api.md) ·
[Examples](#examples) · [Changelog](CHANGELOG.md) · [Documentation site](https://aurthurm.github.io/goose-web/)

Goose Web is early-stage and POSIX-only. Linux is exercised in CI; macOS is not yet verified.
TLS belongs at a reverse proxy. APIs can change before 1.0.

## Start a project

You need Python 3.9+, Git and a C compiler. To build the pinned Goose compiler, also install
CMake 3.27+ and a C++20 compiler; [compiler setup](docs/ci.md) explains the requirements.
If a compatible Goose compiler is already on PATH, skip bootstrap and the two exports.

```sh
git clone https://github.com/aurthurm/goose-web.git
cd goose-web
python3 scripts/bootstrap_goose.py
export GOOSE="$PWD/build/tools/goose/build/goose"
export GOOSE_STDLIB="$PWD/build/tools/goose/source/stdlib"

python3 manage.py new my-app ../my-app
cd ../my-app
python3 manage.py dev --port 8080
```

Open `http://127.0.0.1:8080/` for the starter page, `/docs` for the API UI, or try:

```sh
curl http://127.0.0.1:8080/health
curl -H 'Content-Type: application/json' --data '{"text":"Hello Goose"}' http://127.0.0.1:8080/notes
```

The starter includes typed JSON routes, validation, environment settings, an HTML view, OpenAPI,
a test script, `manage.py` and an optional Makefile. The development command rebuilds on edits
and reloads pages using the live-reload middleware. Ctrl+C stops it.

**Version matching:** the published release is `v0.6.0`. These docs and the current starter include
later changes on `main`. The generator therefore imports the checkout that generated it by
default. Keep that checkout available. To consume a release, use its matching docs and template;
current validation/settings examples do not work with `aurthurm/goose-web@v0.6.0`.

## Use it in your project

A root program can consume the published core package with a pinned import:

```goose
import goose_web from "aurthurm/goose-web@v0.6.0";
```

For current main features, use a matching local checkout instead. SQLite is a separate optional
package; from a project beside the framework checkout, declare both in the root source:

```goose
import goose_web from "../goose-web";
import goose_web_db from "../goose-web/db";
```

Only the root declares package sources. Internal modules import by package name. The SQLite
subdirectory is not independently fetchable as a Git repository; see
[package/release notes](docs/releasing.md#the-db-package). Native package sources and link settings
are handled by the compiler through the imported packages' `.build` files.

## Write a route

This app fragment assumes the root file imports `goose_web`. The
[getting-started guide](docs/guide/getting-started.md) includes the complete executable.

```goose
struct Note { text: u8[..200], pinned: bool = false }

fn web::rules(v: Note&, r: web::Rules&) {
    r.field("text").required().min_len(1).max_len(200);
}

fn app(c: web::Ctx&) {
    request_id(c) {
        c.routes() {
            c.get("/health") { c.text("ok"); };
            c.post("/notes") {
                let note, ok = body<Note>(c);
                guard ok else { return; }
                c.status(web::HTTP_CREATED).json(note);
            };
        };
    };
}
```

Typed inputs reject unknown keys and wrong types. On current main, field constraints share their
definition with OpenAPI and validation failures return a structured 422 list. See
[routing](docs/guide/routing.md), [requests and responses](docs/guide/requests-and-responses.md),
and [validation](docs/guide/validation.md).

## Develop, build and test

Run these in a generated project, or in this checkout (where the default entry is the hello example):

| Python command | Make alias | Purpose |
| --- | --- | --- |
| `python3 manage.py check` | `make check` | Typecheck the entry point |
| `python3 manage.py dev --port 8080` | `make dev PORT=8080` | Rebuild/restart on save |
| `python3 manage.py build` | `make build` | Executable with runtime debug checks |
| `python3 manage.py build --release` | `make release` | Optimized executable |
| `python3 manage.py run -- --port 9000` | `make run ARGS="--port 9000"` | Build and run |
| `python3 manage.py test` | `make test` | Run the project's tests |
| `python3 manage.py ci` | `make ci` | Run checks and propagate failures |

`GOOSE`, `GOOSE_STDLIB`, `GOOSE_CC` and `CC` select the tools. `--entry` and `--output` select a
program and binary. The wrapper uses an absolute build cache. There is no required TOML manifest:
Goose imports declare dependencies, `.build` files describe native code, and the Makefile calls
the same Python commands. [Project tooling](docs/guide/project-tooling.md) explains every command.

## Examples

Run commands from this repository root. SQLite examples need `sqlite3.h` and `libsqlite3`
(`libsqlite3-dev` on Debian/Ubuntu).

| Example | What it teaches |
| --- | --- |
| [Hello](examples/hello/server.goose) | Small app, path parameters, typed JSON |
| [Issue Board](examples/issue-board/README.md) | One entry point, separate modules, projects/issues, SQLite migrations, settings, validation and status transitions |
| [Todo API](examples/basic/README.md) | Domain events, pagination, JSON-file persistence, OpenAPI |
| [SQLite Todos](examples/sqlite-todos/README.md) | Reflective database CRUD, PATCH presence, durable records |
| [Pages](examples/pages/README.md) | Layouts, partials, forms, sessions, CSRF and flash messages |
| [Jobs](examples/jobs/README.md) | Worker-thread CPU jobs, polling, SSE completion and scheduler |
| [SSE clock](examples/sse-clock/server.goose) | Stream lifecycle and heartbeats |
| [TCP echo](examples/tcp-echo/README.md), [chat](examples/tcp-chat/README.md), [proxy](examples/tcp-proxy/README.md) | Custom protocols, framing and backpressure |

```sh
python3 manage.py build --entry examples/issue-board/server.goose --output build/issue-board
./build/issue-board --port 8080
```

Read [project structure](docs/guide/project-structure.md) to follow how the entry imports application
modules, mounts their routes and owns process startup.

## Explore the framework

- [Middleware](docs/guide/middleware.md), [settings](docs/guide/settings.md), [SQLite](docs/guide/database.md)
  and [templates](docs/guide/templates.md) cover everyday application work.
- [Security](docs/guide/security.md) covers authentication, sessions, CSRF and trusted proxies.
- [Jobs](docs/guide/background-jobs.md), [events/SSE](docs/guide/events-and-streaming.md),
  [shared state](docs/guide/shared-state.md) and [TCP](docs/guide/tcp.md) cover additional workloads.
- [Deployment](docs/guide/deployment.md) explains workers, signals, resource limits and logging.
  Mutable globals belong to one worker; shared state is bounded and volatile. Database calls block
  the reactor, so keep transactions short. Job threads accept pure-Goose work, not framework C calls.
- [Troubleshooting](docs/guide/troubleshooting.md) covers source/version mismatches and common build errors.

The [API reference](docs/api.md) owns exact contracts. [Architecture](docs/architecture.md),
[HTTP conformance](docs/http-conformance.md), [security review](docs/security.md),
[roadmap](ROADMAP.md) and [contributing](CONTRIBUTING.md) describe design and project status.

Framework CI runs `python3 manage.py ci` with GCC and Clang. It checks documentation links and
runs debug unit contracts, native tests, real sockets, process lifecycle checks, deterministic
property tests, optional native fuzzers, and the generated starter. See [testing](docs/guide/testing.md)
and [CI setup](docs/ci.md) for local reproduction and optional dependency skips.
