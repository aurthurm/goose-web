# Goose Web

An experimental HTTP framework for the [Goose programming language](https://github.com/aardappel/goose),
with nonblocking network I/O, typed queued events, routing, and composable middleware.
It uses a readiness loop rather than language-level async/await.

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
curl --data 'Hello Goose' http://127.0.0.1:8080/echo
curl http://127.0.0.1:8080/users/42
curl 'http://127.0.0.1:8080/greet?name=Goose+Web'
curl -i -X POST http://127.0.0.1:8080/health
curl -i -H 'X-Demo-Reject: yes' http://127.0.0.1:8080/health
```

The last two demonstrate 405 method errors and a middleware rejection. Every
application response includes a generated `X-Request-ID`. Request events go to
multiple listeners, including a one-shot listener. A full event queue returns 503.

## Project layout

```text
goose_web.goose           Public package entry
goose_web.build           Native build definition
src/
  http/                  Request parsing, response framing, headers, JSON errors
  routing/               Route matching, path parameters, query decoding
  middleware/            Compile-time request pipeline
  events/                Typed bounded event bus
  runtime/               Readiness loop, configuration, lifecycle, metrics
native/posix/            Socket and signal shim
examples/basic/          Runnable application
tests/
  unit/                  Goose contract tests
  native/                C socket tests
  fixtures/              Server programs used by integration tests
  integration/           Real HTTP and runtime checks
  run.py                 Complete test entry point
docs/                    Architecture and API contracts
build/                   Ignored binaries and compiler cache
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
limits, deadlines, metrics, and graceful shutdown on real loopback sockets.

See [Architecture](docs/architecture.md), [API contracts](docs/api.md), and
[Roadmap](ROADMAP.md). The transport is currently POSIX-only; TLS, chunked encoding,
keep-alive, streaming, and language-level async suspension remain future work.
