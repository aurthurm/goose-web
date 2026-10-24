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
| `native/posix/transport.c` | Nonblocking socket calls, the readiness reactor (epoll on Linux, poll elsewhere), optional signals | POSIX |
| `native/posix/system.c` | stat, bounded file read, getenv, clock | POSIX |
| `native/posix/process.c` | fork, nonblocking reap, kill, CPU count, stats record pipe | POSIX (fork and prctl on Linux) |
| `native/posix/shared.c` | The [shared store](api.md#shared-store): entries, counters, the SSE event ring and the stream registry in one `MAP_SHARED` mapping behind a process-shared robust mutex | POSIX (pthreads, `mmap`) |

Keep protocol policy in Goose. The C shim owns no application buffers and retains
no Goose pointers. Its only process-wide state is optional signal ownership; the process calls
in `native/posix/process.c` act on the calling process and its children and keep nothing.
A future Windows transport belongs beside POSIX, with platform build declarations
in `goose_web.build`.

## Request lifecycle and ownership

1. The reactor accepts into one of its bounded connection slots and registers the descriptor.
2. Nonblocking reads fill a block borrowed from the input pool until parsing completes or a limit expires.
3. Middleware checks the borrowed request, then routing selects an application handler.
4. The handler fills an owned response; after-middleware runs even on rejection.
5. Serialization copies the response into the connection's output chunks, then the input block is returned if the connection is idle or closing.
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

## Reactor backend and memory per connection

`native/posix/transport.c` exposes one readiness API that hides the OS mechanism:

| Call | Meaning |
| --- | --- |
| `gw_reactor_open` / `gw_reactor_close` | One reactor per process: an epoll instance on Linux, or nothing extra for poll |
| `gw_reactor_add(token, fd, write)` | Registers a descriptor once under a token (a connection slot, or `LISTENER_TOKEN`) |
| `gw_reactor_modify(token, fd, write)` | Switches read and write interest; a no-op when the interest already matches |
| `gw_reactor_remove(token, fd)` | Unregisters before the descriptor closes; mismatched or unknown tokens are ignored |
| `gw_reactor_wait(tokens, ready, timeout)` | Writes the ready tokens and their states (1 ready, -1 error) and returns the count |

Linux builds use level-triggered epoll. Other systems, and any build with `-DGW_REACTOR_POLL`, keep
the same table and call poll over it, so the two backends are interchangeable. `tests/native/transport.c`
runs the same checks against both. The reactor loop calls `gw_reactor_wait` with the deadline-derived
timeout, as before. Before each wait it syncs interest: a connection is watched for writes only while a
response is queued, and the kernel is called only when that changes, not once per connection per
iteration.

Memory is charged where it is used:

| Storage | Cost | Lifetime |
| --- | --- | --- |
| Connection record | about 200 bytes inline in the reactor's `clients` array, all 64 slots | the whole run |
| Input block | 1 KiB while a connection holds unparsed bytes, doubling to `max_request_bytes` (at most 8 KiB) | taken when bytes arrive, returned when the connection goes idle or closes |
| Response chunks | 16 KiB chunks from the shared pool, bounded by `max_pool_bytes` | returned as each chunk is sent |
| SSE outbox (`sse_outbox`) | 0 bytes until the first `sse_publish`, at most 256 KiB | reactor-owned global; drained every iteration |

Input blocks come from `InputPool` in `src/runtime/server.goose`, a grow-only pool with one free list per
block class (1 KiB, 2 KiB, 4 KiB, 8 KiB, capped by `max_request_bytes`). A block never moves, so the `Request`
views a handler reads stay valid. A full block is replaced by the next class, copying its bytes; a block is
released only after the response is staged and no unparsed bytes remain, or when the connection closes.
Freed blocks are kept for reuse rather than returned to the OS, so the pool holds the peak. Each class has
at most `MAX_CLIENTS` blocks, because a live block belongs to one connection.

`ServerControl` stays fixed-size and small so `default<web::ServerControl>()` works and costs nothing
for the outbox. Its messages live in the reactor-owned `sse_outbox`, which `sse_publish` appends to and
the reactor copies from; the public signature is unchanged.

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
- The shared store is the one region that workers do see in common. `serve_config` creates it before the
  fork, so it is inherited, and every access takes its robust mutex. It carries the state that must agree
  across workers: entries and counters, `rate_limit` counts, server-side sessions and the SSE event ring
  (each worker copies new events to its own streams). Its layout and crash rules are in
  [docs/api.md](api.md#shared-store).
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
