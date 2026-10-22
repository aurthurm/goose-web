# Architecture and maintenance

## Dependency boundaries

`goose_web.goose` is the public package facade. It imports focused modules; application
code should import the facade instead of depending on individual source paths.
All modules declare `namespace web` because Goose imports files without creating namespaces.

| Directory | Responsibility | Dependencies |
| --- | --- | --- |
| `src/constants/` | Public HTTP identifiers, fixed capacities, runtime defaults | No runtime state |
| `src/http/types.goose` | Shared request, response, and header data | Goose stdlib |
| `src/http/headers.goose` | Header validation and owned response headers | HTTP types |
| `src/http/request.goose` | Incremental request parsing and borrowed header lookup | HTTP types, headers |
| `src/http/response.goose` | Response defaults and wire framing | HTTP types, headers |
| `src/http/errors.goose` | Bounded escaped JSON error responses | HTTP response |
| `src/routing/router.goose` | Descriptors, path matching, query decoding | Goose stdlib |
| `src/middleware/pipeline.goose` | Before/handler/after composition | HTTP types |
| `src/events/bus.goose` | Typed subscriptions and queued dispatch | Goose stdlib |
| `src/runtime/server.goose` | Connections, deadlines, shutdown, lifecycle, counters | HTTP parsing/framing, native transport |
| `native/posix/transport.c` | Nonblocking socket calls, readiness, optional signals | POSIX |

Keep protocol policy in Goose. The C shim owns no application buffers and retains
no Goose pointers. Its only process-wide state is optional signal ownership.
A future Windows transport belongs beside POSIX, with platform build declarations
in `goose_web.build`.

## Request lifecycle and ownership

1. The reactor accepts into one of its bounded connection slots.
2. Nonblocking reads fill that slot's owned buffer until parsing completes or a limit expires.
3. Middleware checks the borrowed request, then routing selects an application handler.
4. The handler fills an owned response; after-middleware runs even on rejection.
5. Serialization copies the response into the connection's output buffer.
6. Nonblocking writes resume from the previous byte offset until complete, then close.

Request slices and path parameters must not escape their owning request/router.
Queue owned event arguments for work that survives the handler. No callback suspends;
blocking a callback stalls the reactor.

## Composition

Goose function values exist at compile time. Middleware callbacks and runtime callbacks
are generic function parameters rather than stored function objects. Route descriptors
are a bounded runtime table of method/pattern/handler IDs; the application selects named
handlers through a `match`. Adding routes does not add function pointers or dynamic closures.

The event bus copies fixed-size arguments. Each drain takes a batch snapshot so listeners
cannot continually enqueue work and starve the reactor. Cross-thread delivery is not supported.

## Adding functionality

- HTTP behavior belongs in its specific HTTP module with unit tests under `tests/unit/`.
- Routing and middleware rules belong in their respective modules, not the reactor.
- New transport primitives need native tests under `tests/native/`.
- Server lifecycle/limits need fixtures under `tests/fixtures/` and live checks under `tests/integration/`.
- Reproducible parser fuzz/property checks belong under `tests/fuzz/`; preserve seeds and regression cases.
- Keep `tests/run.py` as the single complete verification command; register new unit programs there.
- Keep generated binaries/cache under ignored `build/`; keep examples out of `src/`.

The basic example is a Todo API: `server.goose` wires middleware, events and lifecycle;
`todos/store.goose` owns records and atomic persistence, `todos/input.goose` validates
payloads and query values, and `todos/api.goose` handles routes and transactional state swaps.
Its OpenAPI contract and curl walkthrough live beside the example. File writes are
synchronous and bounded by the small store; callbacks still run on the reactor thread.
The old routing/middleware feature demonstration is retained in `tests/fixtures/features.goose`.
