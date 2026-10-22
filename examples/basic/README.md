# Basic Todo API

This example turns Goose Web routing, middleware, typed events, and lifecycle
handling into a small JSON API. Its local contract is [openapi.yaml](openapi.yaml).
It supports up to 128 Todos and returns at most eight per list request.

## Run

From the repository root, using the installed Goose compiler:

```sh
mkdir -p build
goose build examples/basic/server.goose --debug -o build/server
./build/server 8080 0 build/todos.json
```

Arguments are `[port=8080] [max_responses=0] [datafile=build/todos.json]`.
A zero response limit runs until shutdown. A positive limit triggers graceful
shutdown after that many completed responses; accepted work may finish during
draining. The server binds to loopback. Ctrl+C requests graceful shutdown.
Use `--memory` as the third argument to disable persistence:

```sh
./build/server 8080 0 --memory
```

The data directory must already exist. Successful mutations replace the JSON data
file atomically. Invalid existing data aborts startup; it is never silently reset.
A save failure returns `500` with code `storage_error` and preserves live state,
including the next ID. This is a single-process example; use one server per data
file. Atomic replacement does not provide multi-process coordination.

## Try it

```sh
curl http://127.0.0.1:8080/health
curl -i -H 'Content-Type: application/json' \
  --data '{"title":"Learn Goose Web"}' http://127.0.0.1:8080/todos
curl 'http://127.0.0.1:8080/todos?limit=8&offset=0&completed=false'
curl http://127.0.0.1:8080/todos/1
curl -X PUT -H 'Content-Type: application/json' \
  --data '{"title":"Build an API","completed":false}' http://127.0.0.1:8080/todos/1
curl -X PATCH -H 'Content-Type: application/json' \
  --data '{"completed":true}' http://127.0.0.1:8080/todos/1
curl -i -X DELETE http://127.0.0.1:8080/todos/1
```

A Todo is `{"id":1,"title":"Learn Goose Web","completed":false}`. Creation
returns `201` and a `Location` header. PUT requires both editable fields; PATCH
requires at least one. DELETE returns `204` with no body. IDs are positive,
canonical decimal numbers, increase monotonically, and remain unused after
deletion and restart. GET endpoints also support HEAD, returning representation
headers with no response body.

List responses contain `items`, `total`, `limit`, and `offset`. Items are ordered
by ascending ID. The optional `completed=true|false` filter runs before pagination;
`total` counts matching items before pagination. Limit defaults to eight and must
be 1..8. Offset defaults to zero and must be nonnegative. Unknown or duplicate
query keys are rejected, including duplicates hidden by percent encoding.

## Validation and errors

POST, PUT, and PATCH require the JSON media type. Objects reject unknown and
duplicate fields, including duplicate names written with JSON escapes. Titles
must occupy 1..128 UTF-8 bytes, not consist entirely of Unicode whitespace, and contain no ASCII control
characters or DEL. Unicode is validated and preserved
without normalization; leading/trailing spaces are preserved.

| Status | Meaning |
| --- | --- |
| 400 | Malformed JSON or invalid URI escape |
| 404 | Route or valid Todo ID not found |
| 405 | Method unavailable; `Allow` lists the supported methods |
| 409 | Store contains 128 Todos |
| 413 | Query field exceeds its decoded byte limit, or request exceeds framework limits |
| 415 | Required JSON media type is missing or unsupported |
| 422 | JSON shape/types, title, ID, or query validation failed |
| 500 | Persistent save failed (`storage_error`) |
| 503 | Required event queue is full (`event_queue_full`) |

Application errors use `{"error":{"code":"...","message":"..."}}`; every
application response includes `X-Request-ID`. HTTP parser errors occur before
middleware, so they can use plain text without a request ID. Required domain
events are admitted before mutation; queue backpressure returns 503 without
changing the Todo store. Domain events are enqueued only for successful mutations.

The earlier `/echo`, `/greet`, and `/users` routes are not part of this API.

## Verify

The repository runner builds the example and includes its real HTTP tests:

```sh
python3 tests/run.py
```

To test an already-built binary directly:

```sh
python3 tests/integration/todos.py "$PWD/build/server"
```

Tests use temporary data files and ephemeral local ports. They cover CRUD,
filtering/pagination, HEAD and method errors, Unicode/escaped JSON, validation,
capacity, restart persistence, corrupt startup, and rollback after storage errors.
