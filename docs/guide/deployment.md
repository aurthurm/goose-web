# Deployment and runtime operations

**Version:** Basic runtime configuration, worker processes and graceful HTTP shutdown are in
published `v0.6.0`. `json_logger`, trusted proxies, ETag and load shedding described here are on
`main`, not in that published package.

Start from `web::server_config()` or `config_from_args(args())`, validate configuration, then
call `web::run`/`run_with`. The server binds to loopback by default; make a public bind an explicit
choice, usually behind a TLS-terminating reverse proxy. The framework's HTTP server does not
terminate TLS.

For a local multi-worker run, build the hello example and pass the worker count:

```sh
mkdir -p build
goose build examples/hello/server.goose -o build/hello
./build/hello --port 8080 --workers 4
curl http://127.0.0.1:8080/health
```

`--workers N` and `GOOSE_WEB_WORKERS=N` enable pre-fork workers (`0` means one per online CPU).
Argument parsing and environment parsing are separate helpers: `config_from_args(args())`
reads flags, while `config_from_env()` reads `GOOSE_WEB_PORT`, `GOOSE_WEB_PUBLIC` and
`GOOSE_WEB_WORKERS`. Calling the argument helper does not automatically apply the environment
helper. Choose a precedence policy explicitly if your app needs both.

Each worker has private program memory: mutable globals, scheduler tables and the typed event bus
are not shared. Use SQLite or an external database for durable state, or the bounded shared store
for small volatile cross-worker values. The shared store and its shared sessions, cross-worker
SSE, and worker-wide rate-limit behavior are on `main`, not published `v0.6.0`. Open SQLite
connections only after fork in each worker. The shared store is per server instance and is cleared
on restart.

Limits are per worker for connection slots, SSE clients and response-pool bytes, so multiply those
when estimating process-wide capacity. `max_requests` is also enforced per worker. Worker exits
are supervised and restarted within a bounded budget; repeated failures stop the server.

For shutdown, enable `handle_signals` when the application owns SIGINT/SIGTERM handling. The
framework drains active requests during `shutdown_grace_ms`, sends a close event to SSE clients,
then force-closes remaining connections. In multi-worker mode the parent owns shutdown and drains
workers. Use the lifecycle callback for cleanup: stop and join job pools at `SERVER_STOPPING`, and
close resources owned by that process. Signal ownership is process-wide, so embedders should
manage signals externally if they already have a handler.

Install `json_logger` to emit one JSON object per request. `etag` applies to eligible 200 GET/HEAD
responses after inner middleware; it does not add tags to static-file responses unless wrapped
appropriately, and SSE is left unchanged. `shed_load` can return 503 under connection or pool
pressure. Use `trust_proxies` only with a configured allow-list of actual proxy peers.

Keep stdout/stderr connected to the service manager to retain request logs and worker restart
errors. For a single worker, use `workers = 1` unless the app's mutable state is process-safe.
The [starter project](../../templates/starter/server.goose) demonstrates settings and startup.
See [runtime configuration](../api.md#runtime-configuration-and-lifecycle),
[worker processes](../api.md#worker-processes), [structured logs](../api.md#structured-logs),
and [ETag](../api.md#etag) for exact behavior.
