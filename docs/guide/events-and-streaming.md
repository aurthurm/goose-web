# Events and streaming

**Version:** SSE and the typed event bus are available in the published `v0.6.0` package. The
shared store, cross-worker SSE fan-out, and worker-wide server-side session/rate-limit state are
on `main`. The sample below is a complete single-process SSE app.

Goose has three related but distinct mechanisms: an in-process typed event bus, HTTP server-sent
events (SSE) for browser/client streams, and a shared event ring used to fan SSE messages across
worker processes. Choose based on who needs to receive the event.

## Typed event bus

Use `event_bus<T>()` for synchronous application listeners on one reactor thread. `dispatch`
queues owned fixed-size values; call `drain` where callbacks should run. The queue holds 256
events and `dispatch` returns false when full. The bus is neither cross-thread nor cross-process.
If a mutation must not happen unless its notification can be queued, check capacity/dispatch
before side effects; a later 503 cannot undo work already performed. See [Events API](../api.md#events).

## SSE

An HTTP GET route calls `c.sse(channel)` and returns. Publish with
`web::sse_publish(control, channel, event, data)`, typically from a tick or after a completed
operation:

```goose
import goose_web from "../goose-web";
import std;
import os;

const CHANNEL = 1;
var control = default<web::ServerControl>();
var last_second: i64 = -1;

fn tick() {
    let second = time_ns() / 1000000000;
    if second != last_second {
        last_second = second;
        web::sse_publish(control, CHANNEL, "tick", str(second));
    }
}
fn app(c: web::Ctx&) {
    c.routes() { c.get("/events") { c.sse(CHANNEL); }; };
}
fn main() {
    var config = web::server_config();
    config.handle_signals = true;
    let started = web::run_with(config, control, app, tick, web::ignore_lifecycle);
    if !started { abort("server failed"); }
}
```

From the repository root, create `build`, compile with `goose build examples/sse-clock/server.goose -o build/sse-clock`,
and run `./build/sse-clock --port 8080`. Connect with
`curl -N http://127.0.0.1:8080/events`.
The browser `EventSource` page and clock formatting are in the full
[SSE clock example](../../examples/sse-clock/server.goose).

SSE is chunked HTTP/1.1, bounded by client and queued-byte limits. Slow readers are dropped when
their queue fills. Heartbeats are comments, and shutdown sends a `close` event then terminates the
stream subject to shutdown grace. Keep event payloads bounded and handle reconnects in clients.

## Across worker processes

By default the shared store is enabled, and its event ring carries `sse_publish` messages to every
worker's local streams. Disabling `shared_store_bytes` removes that cross-worker fan-out; in that
case publishes reach only streams in the same process. The ring is volatile and bounded, so it is
not a durable message broker. The in-process typed event bus does not become shared when workers
are enabled.

Full semantics and failure returns: [SSE API](../api.md#server-sent-events),
[shared store](../api.md#shared-store), and [worker processes](../api.md#worker-processes).
