# Goose Web

[![Linux CI](https://github.com/aurthurm/goose-web/actions/workflows/ci.yml/badge.svg)](https://github.com/aurthurm/goose-web/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/tag/aurthurm/goose-web?label=release&sort=semver)](https://github.com/aurthurm/goose-web/tags)
[![Docs](https://img.shields.io/badge/docs-GitHub%20Pages-blue)](https://aurthurm.github.io/goose-web/)

[Documentation site](https://aurthurm.github.io/goose-web/) · [Starter project](templates/starter/README.md) ·
[API reference](docs/api.md) · [Changelog](CHANGELOG.md)

An experimental HTTP framework for the [Goose programming language](https://github.com/aardappel/goose),
with nonblocking network I/O, typed queued events, routing, and composable middleware.
It uses a readiness loop rather than language-level async/await.

## Hello world

```goose
import goose_web from "path/to/goose-web";
import std;

struct Health { status: u8[..8] }
struct Note { text: u8[..64], pinned: bool = false }

fn app(c: web::Ctx&) {
    request_id(c) { c.logger() {
        c.routes() {
            c.get("/health") { c.json(Health { status: "ok" }); };
            c.post("/notes") {
                let note, ok = body<Note>(c);
                guard ok else { return; }
                c.status(web::HTTP_CREATED).json(note);
            };
        };
    }};
}

fn main() {
    var config = web::server_config();
    config.port = 8080;
    let started = web::run(config) { c => app(c) };
    if !started { abort("server failed"); }
}
```

`examples/hello/server.goose` is this program with a path-parameter route added.

## Features

- Typed routing DSL: `c.get`/`post`/`put`/`patch`/`delete`, `:param` segments, `c.group` prefixes, automatic 404 and 405 with `Allow`.
- Routing extras: `*name` wildcards for the rest of a path, `c.host(...)` scopes by Host (exact or `*.example.com`), and typed `param_int`, `param_u64`, `param_uuid` and `param_slug` path parameters. See [routing](docs/api.md#routing-dsl).
- OpenAPI 3.1 from the routes block and struct reflection, served at `/openapi.json` with a `/docs` page (`web::openapi`).
- Field names and skipping for JSON, typed queries and OpenAPI: `web::json_key` renames a field (`completed` as `done`), `web::json_skip` leaves it out. See [API contracts](docs/api.md#field-names-and-skipping).
- Reflective JSON in and out: `body<T>(c)` decodes strict structs (415, 400, 422 written for you); `c.json(value)` encodes any struct.
- Typed forms and query strings: `form<T>(c)` binds urlencoded bodies and `query<T>(c)` binds the query, both strict.
- Compile-time HTML templates: `embed_file("views/page.html")` with `{{escaped}}`, `{{{raw}}}`, sections, `each` over struct arrays and comments; `check_template` validates them at startup. See [Templates](docs/api.md#templates).
- Composable middleware: built-in `request_id`, `logger`, `cors` and `require_json`, or your own `fn name<Next>(c)`.
- Development loop: `python3 scripts/dev.py server.goose` rebuilds and restarts on save, and the page reloads (or shows the compiler error). `web::live_reload` is the browser side. See [development server](docs/api.md#development-server-and-live-reload).
- Edge middleware: `secure_headers` (CSP, nosniff, frame DENY, referrer policy, optional HSTS) and a bounded per-client `rate_limit` that answers 429 with `Retry-After`. `c.peer()` gives the TCP peer address.
- Signed cookie sessions (`session`, 16 entries, HMAC-SHA256) and double-submit CSRF protection (`csrf`) with a CSPRNG-backed token. See [Sessions](docs/api.md#sessions) and [CSRF](docs/api.md#csrf); the security notes there say what these do not protect.
- Opt-in SQLite layer (`db/`, `web::db`): reflective tables and CRUD from `fields<T>`, bound parameters only, a query builder, transactions, migrations. See [SQLite](docs/api.md#sqlite-webdb).
- Nonblocking reactor: epoll readiness on Linux (poll elsewhere) with one registration per connection, bounded client slots, partial writes, read and write deadlines.
- Multi-core serving with pre-forked worker processes (`--workers N`, `0` for one per CPU): shared listener, supervised restarts, graceful drain, aggregated stats. Per-worker state is documented in [worker processes](docs/api.md#worker-processes).
- Server-sent events: `c.sse(channel)` upgrades a route to a chunked event stream, `web::sse_publish` fans events out per channel, with heartbeats, bounded per-stream queues that drop slow readers, and a close event at shutdown. See [SSE](docs/api.md#server-sent-events) and the [sse-clock example](examples/sse-clock/README.md).
- Scheduler and background jobs: `web::every`, `web::after` and `web::due` run tasks from the tick on the reactor with a documented catch-up rule. `web::job_pool` runs pure-Goose work on threads over bounded queues, with a 503 when full, lost-job reporting and worker restarts. See [scheduler](docs/api.md#scheduler), [background jobs](docs/api.md#background-jobs) and the [jobs example](examples/jobs/README.md).
- Bounded memory: fixed capacities for headers, routes, queues and clients; request input and response bodies grow on demand (input up to `max_request_bytes`, responses up to `max_response_bytes`, 1 MiB default, 16 MiB ceiling), in-flight responses share a pool capped by `max_pool_bytes`, and idle connections hold no input memory. `examples/hello` starts at about 3.2 MB resident.
- Typed event bus: subscriptions, one-shot listeners, FIFO queue with visible backpressure.
- Graceful shutdown: SIGINT and SIGTERM stop accepting, drain within a grace period, and report lifecycle stages.
- Strict HTTP/1.1 request profile: bounded framing, validated targets and Host, explicit 400/413/417/501 rules.
- Validated runtime configuration: ports, limits, timeouts and request caps are checked before a socket opens.
- Tested end to end: unit contracts, native socket tests, real loopback integration tests and parser fuzz/property checks.

## Use it in your project

Goose Web is a Goose package. A program declares it in its root file, and `goose` fetches it,
builds its C once, and caches both under `~/.goose` (the [packaging guide](https://github.com/aardappel/goose)
in the Goose repository explains the rules; `goose fetch program.goose` fetches ahead of a build).

The fastest start is the [starter project](templates/starter/README.md):

```sh
python3 scripts/new_project.py my-api ../my-api --source .   # "." is this checkout
cd ../my-api && goose run server.goose -- 8080              # or: goose build server.goose -o build/server
python3 test.py                                             # builds, calls every route, stops the server
```

Leave out `--source` to write the GitHub tag form instead (`aurthurm/goose-web@v0.6.0`); that
needs the tag to exist.

By hand, the root file declares the package with its source:

```goose
import goose_web from "aurthurm/goose-web@v0.6.0";   // GitHub, at a release tag
import std;

fn app(c: web::Ctx&) {
    c.routes() {
        c.get("/health") { c.text("ok"); };
    };
}

fn main() {
    var config = web::server_config();
    config.port = 8080;
    let started = web::run(config) { c => app(c) };
    if !started { abort("server failed"); }
}
```

Other sources use the same `import goose_web from "...";` line. A local checkout is used in place,
and was checked by building and running a consumer:

```goose
import goose_web from "../goose-web";                          // a local checkout, used in place
import goose_web from "github.com/aurthurm/goose-web@3f2c1a9";  // a commit, per packages.md (not yet checked here)
```

The GitHub tag form was checked against the published `v0.6.0` tag: a consumer program with the
import above ran `goose fetch` and `goose build` cleanly, and its `/health` route answered `200 ok`.
Fetching it needs network access and the tag; before the tag exists, `goose fetch` stops with
`Remote branch v0.6.0 not found`.

The SQLite layer is a second package in `db/`, with its own sidecar. A program that uses it declares
both packages from the same version:

```goose
import goose_web from "../goose-web";
import goose_web_db from "../goose-web/db";   // the same checkout; SQLite is linked only here
```

`db/` is not a repository of its own, so it cannot be fetched from GitHub by path yet; see
[releasing](docs/releasing.md#the-db-package).

Releases are tagged `vX.Y.Z`; the history is in [CHANGELOG.md](CHANGELOG.md). `web::VERSION` holds
the release a program was built with, and it matches the `VERSION` file.

## Run locally

Requires upstream Goose (tested with runtime `4d3da949e563`), a C compiler, and Linux
or macOS. Linux is tested; macOS is not yet verified. Python 3.9+ runs the test suite.

```sh
mkdir -p build
goose build examples/basic/server.goose -o build/server
./build/server 8080
```

The example listens on `127.0.0.1`. Ctrl+C or SIGTERM stops accepting clients and
drains existing connections within a five-second grace period.

While you develop, `python3 scripts/dev.py examples/hello/server.goose --port 8080` rebuilds and restarts
the program on each save. Pages that use `web::live_reload` also reload in the browser; see
[the development server](docs/api.md#development-server-and-live-reload).

To use every core, pre-fork worker processes. Apps whose `main` calls `web::config_from_args`
accept `--workers N` (`0` for one per CPU) and read `GOOSE_WEB_WORKERS`:

```sh
goose build examples/hello/server.goose -o build/hello
./build/hello --port 8080 --workers 0     # one worker process per CPU
```

The basic Todo example keeps its store in memory, so each worker would hold its own list; run it
with the default single process. `examples/sqlite-todos` keeps its data in a file and works with
several workers. A load generator for measurements is in `bench/load.c`:
`cc -O2 bench/load.c -o build/load`, then `build/load -c 64 -d 5 -p /health`.

```sh
curl http://127.0.0.1:8080/health
curl -i -H 'Content-Type: application/json' \
  --data '{"title":"Try Goose Web"}' http://127.0.0.1:8080/todos
curl http://127.0.0.1:8080/todos
curl -X PATCH -H 'Content-Type: application/json' \
  --data '{"completed":true}' http://127.0.0.1:8080/todos/1
curl -i -X DELETE http://127.0.0.1:8080/todos/1
```

The example is a [complete Todo API](examples/basic/README.md), including validation,
pagination, filtered lists, and atomic JSON-file persistence in `build/todos.json`.
Every application response includes a generated `X-Request-ID`. Request events go
to multiple listeners; successful mutations also dispatch domain events. A full
event queue returns 503 before a mutation can change data. The API is documented at
`/openapi.json` (generated from the routes) with a Swagger UI page at `/docs`. The hand-written
[contract](examples/basic/openapi.yaml) adds what the generated spec does not express yet.

## Project layout

```text
goose_web.goose           Public package entry (the fetched package's entry)
goose_web.build           Native build definition (the package's sidecar)
VERSION                   Release version, checked against web::VERSION by tests/run.py
CHANGELOG.md              Release notes
src/
  constants/              Public HTTP names, fixed limits, runtime defaults
  http/                   Request parsing, response framing, headers, JSON errors
  json/                   Reflective struct codec over fields<T>
  routing/                Route matching, path parameters, query decoding
  middleware/             Compile-time request pipeline
  app/                    Application API: Ctx, c.routes/c.group, middleware, responses, forms, templates, run, config
  sys/                    File, environment, clock and crypto (SHA-256, HMAC, CSPRNG, base64url) access over the native shim (no os import)
  events/                 Typed bounded event bus
  jobs/                   Background job pool: pure-Goose worker threads over typed queues
  runtime/                Readiness loop, scheduler, configuration, lifecycle, metrics, worker processes
native/posix/             Socket, signal, file, environment and process shim
db/                       Opt-in SQLite package (goose_web_db): query builder, typed records, C shim
bench/load.c              Keep-alive HTTP load generator for benchmarks
examples/hello/           Smallest app: health, path parameter, typed POST
examples/basic/           Todo API, OpenAPI contract, and application modules
examples/sqlite-todos/    Todo API persisted in a SQLite file through web::db
examples/pages/           Server-rendered todo list: embedded templates and a form POST
examples/jobs/            Background prime counts on worker threads, SSE completion, scheduled cleanup
tests/
  unit/                   Goose contract tests (including the SQLite layer on :memory:)
  native/                 C socket, system, crypto and process tests
  fixtures/               Server programs used by integration tests
  integration/            Real HTTP and runtime checks
  fuzz/                   Reproducible parser fuzz/property corpus
  run.py                  Complete test entry point
docs/                     Architecture, API contracts, releasing, and the docs site (docs/site)
templates/starter/        Starter project copied by scripts/new_project.py
scripts/                  Pinned compiler bootstrap and the starter generator
.github/workflows/        Linux CI with GCC and Clang; Pages publishes docs/site
build/                    Ignored binaries and compiler cache
```

Applications use `import goose_web from "../..";` from `examples/basic/`, or a
relative package path appropriate to their own location. Internal files share
`namespace web`; importing the package entry exposes the public functions.

## Verify

```sh
python3 tests/run.py
```

Set `GOOSE=/opt/goose/goose` if Goose is not on PATH; `CC` selects the C compiler. The SQLite
layer and its example need `sqlite3.h` and `libsqlite3` (`libsqlite3-dev`); without them `run.py`
prints a SKIP line and runs everything else.
The suite builds with Goose runtime checks, checks event and application contracts,
forces partial writes, and verifies concurrent clients, routing, middleware, request
limits, deadlines, metrics, and graceful shutdown on real loopback sockets. It also
runs 33,119 deterministic parser fuzz/property checks using four recorded seeds.
Todo tests also exercise CRUD, validation, persisted restarts, capacity, and failed-save rollback.

See [Architecture](docs/architecture.md), [API contracts](docs/api.md),
[HTTP request profile](docs/http-conformance.md), and [Roadmap](ROADMAP.md).
Use the [public constants](docs/constants.md) for statuses such as `web::HTTP_NOT_FOUND`,
methods such as `web::METHOD_GET`, content types, capacity limits, and runtime defaults.
See [CI and compiler setup](docs/ci.md) to build the pinned upstream compiler and
reproduce both C compiler configurations locally.
The transport is currently POSIX-only; TLS, chunked encoding,
streaming, and language-level async suspension remain future work.
