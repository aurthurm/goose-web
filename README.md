# Goose Web

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
- Reflective JSON in and out: `body<T>(c)` decodes strict structs (415, 400, 422 written for you); `c.json(value)` encodes any struct.
- Composable middleware: built-in `request_id`, `logger`, `cors` and `require_json`, or your own `fn name<Next>(c)`.
- Nonblocking reactor: poll-based readiness, bounded client slots, partial writes, read and write deadlines.
- Bounded memory: fixed capacities for requests, headers, routes, responses, queues and clients.
- Typed event bus: subscriptions, one-shot listeners, FIFO queue with visible backpressure.
- Graceful shutdown: SIGINT and SIGTERM stop accepting, drain within a grace period, and report lifecycle stages.
- Strict HTTP/1.1 request profile: bounded framing, validated targets and Host, explicit 400/413/417/501 rules.
- Validated runtime configuration: ports, limits, timeouts and request caps are checked before a socket opens.
- Tested end to end: unit contracts, native socket tests, real loopback integration tests and parser fuzz/property checks.

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
event queue returns 503 before a mutation can change data. The local contract is
[OpenAPI](examples/basic/openapi.yaml).

## Project layout

```text
goose_web.goose           Public package entry
goose_web.build           Native build definition
src/
  constants/              Public HTTP names, fixed limits, runtime defaults
  http/                   Request parsing, response framing, headers, JSON errors
  json/                   Reflective struct codec over fields<T>
  routing/                Route matching, path parameters, query decoding
  middleware/             Compile-time request pipeline
  app/                    Application API: Ctx, c.routes/c.group, middleware, responses, run
  events/                 Typed bounded event bus
  runtime/                Readiness loop, configuration, lifecycle, metrics
native/posix/             Socket and signal shim
examples/hello/           Smallest app: health, path parameter, typed POST
examples/basic/           Todo API, OpenAPI contract, and application modules
tests/
  unit/                   Goose contract tests
  native/                 C socket tests
  fixtures/               Server programs used by integration tests
  integration/            Real HTTP and runtime checks
  fuzz/                   Reproducible parser fuzz/property corpus
  run.py                  Complete test entry point
docs/                     Architecture and API contracts
scripts/                  Pinned compiler bootstrap
.github/workflows/        Linux CI with GCC and Clang
build/                    Ignored binaries and compiler cache
```

Applications use `import goose_web from "../..";` from `examples/basic/`, or a
relative package path appropriate to their own location. Internal files share
`namespace web`; importing the package entry exposes the public functions.

## Verify

```sh
python3 tests/run.py
```

Set `GOOSE=/opt/goose/goose` if Goose is not on PATH; `CC` selects the C compiler.
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
