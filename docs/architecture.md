# Architecture and maintenance

## Dependency boundaries

`goose_web.goose` is the public package facade. It imports focused modules; application
code should import the facade instead of depending on individual source paths.
All modules declare `namespace web` because Goose imports files without creating namespaces.
Framework files must not import the `os` stdlib: its global names would collide with every application's
own globals (a Goose import adds no namespace). Use `src/sys/` instead.

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
| `src/json/codec.goose` | Reflective struct to JSON encode and strict decode over `fields<T>` | Goose stdlib `json`, HTTP errors |
| `src/app/` | Application API: `Ctx`, `c.routes`/`c.group`, built-in middleware, JSON responses and bodies, `run` | HTTP, routing, JSON codec, runtime server |
| `src/events/bus.goose` | Typed subscriptions and queued dispatch | Goose stdlib |
| `src/sys/` | Files (stat, bounded read), environment, monotonic clock | Native shim only; never imports the `os` stdlib |
| `src/app/config.goose` | `config_from_args` / `config_from_env` for application mains | Runtime config, `src/sys` |
| `src/runtime/server.goose` | Connections, deadlines, shutdown, lifecycle, counters; worker processes (`serve_workers`) | HTTP parsing/framing, native transport, `src/sys` |
| `native/posix/transport.c` | Nonblocking socket calls, readiness, optional signals | POSIX |
| `native/posix/system.c` | stat, bounded file read, getenv, clock | POSIX |
| `native/posix/process.c` | fork, nonblocking reap, kill, CPU count, stats record pipe | POSIX (fork and prctl on Linux) |

Keep protocol policy in Goose. The C shim owns no application buffers and retains
no Goose pointers. Its only process-wide state is optional signal ownership; the process calls
in `native/posix/process.c` act on the calling process and its children and keep nothing.
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

### Application state ownership

The per-request `Ctx` (`src/app/context.goose`) is small: the request view, the borrowed
response, the matched route, the group prefix stack, and the describe text buffer. Large state
lives in an `AppScratch` that the caller owns, and `Ctx` refers to its parts:

| State | Owner | How `Ctx` reaches it |
| --- | --- | --- |
| Route table (`Router`, 64 routes) | `AppScratch.table` | `Ctx.table: Router&` |
| Session store (`SessionState`) | `AppScratch.session_state` | `Ctx.session_state` |
| CSRF token (`CsrfState`) | `AppScratch.csrf_state` | `Ctx.csrf_state` |
| OpenAPI config, pending annotations, operation index (`OpenApiState`) | `AppScratch.oas` | `Ctx.oas` |
| OpenAPI document text (growable) | `Ctx.oas_text` | the `Ctx` itself, empty per request |

- `run` / `run_with` own one `app_scratch` global (`src/app/run.goose`). Handlers run one at a time on
  the reactor thread, so one scratch serves every request. Tests that hold several `Ctx` at once each
  declare their own `AppScratch` and pass it to `new_ctx(request, response, scratch)`.
- `new_ctx` calls `scratch_reset`, which clears only what a request reads before writing: the route
  count, the session and CSRF flags and counts, the OpenAPI enable flag and operation count. Entries,
  route patterns and OpenAPI fragments are not cleared; they are guarded by those counts.
- The describe text is a growable buffer, so it is the last field of `Ctx`. A growable buffer in the
  scratch could not be cleared while the request is live, because Goose cannot prove a caller-supplied
  request holds no slice into it.

## Process model

One process runs the reactor by default. `workers` other than 1 pre-forks worker processes, which is how the
framework uses every core without threads: Goose threads share no memory and may not call the transport
(`goose_web.build` declares `main_thread_only`), and a process gives the same isolation with crash containment.

- The parent (`serve_workers`, in `src/runtime/server.goose`) opens the listener, owns signals, forks the
  workers, supervises them and aggregates their stats. It never handles a request.
- A worker is `serve_loop`, the same reactor as the single-process path, on the inherited listener, with
  `workers = 1`. `serve_config` with `workers = 1` opens its own listener and calls the same loop, so the
  single-process behavior is the code path it always was.
- Worker state is copied at fork and is private afterwards; SQLite connections are opened after fork
  (see [docs/api.md](api.md#worker-processes)). Only the stats record crosses back, over one pipe.
- The shim functions for this live in `native/posix/process.c`; `tests/native/process.c` covers them.

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
- Load measurement uses `bench/load.c` (keep-alive, fixed duration); it is not part of `tests/run.py`.

The basic example is a Todo API built on the application API. `server.goose` declares the
middleware chain (`request_id`, `logger`, a request event), the event bus and lifecycle, and
calls `web::run_with`. `todos/api.goose` declares the routes under `c.group("/todos")` and
commits each mutation transactionally; `todos/store.goose` owns the records, their invariants
and atomic persistence through the JSON codec; `todos/query.goose` parses the strict list query.
`examples/hello/server.goose` is the smallest app and is smoke-tested by `tests/integration/hello.py`.
The Todo OpenAPI contract and curl walkthrough live beside the example. File writes are
synchronous and bounded by the small store; callbacks still run on the reactor thread.
The old routing/middleware feature demonstration is retained in `tests/fixtures/features.goose`.
