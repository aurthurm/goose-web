# SSE clock

A server-sent events example. The tick publishes the UTC time on channel 1 once per second,
and each browser that opens `/events` receives it as a `time` event. The page in
`public/index.html` uses `EventSource` to show the time, and it closes the stream when the
server sends its `close` event at shutdown.

## Run

From the repository root, so the static directory resolves:

```sh
mkdir -p build
goose build examples/sse-clock/server.goose -o build/sse_clock
./build/sse_clock --port 8080
```

Open <http://127.0.0.1:8080/static/> in a browser. Stop the server with Ctrl+C: streams
get the `close` event and the terminating chunk, then the page shows "server stopped".

To watch the raw stream:

```sh
curl -N http://127.0.0.1:8080/events
```

## What it shows

- `c.sse(1)` in a route upgrades the connection to a chunked `text/event-stream` response.
- `web::sse_publish(control, 1, "time", text)` is called from `tick`, once per second. The
  reactor sends it to every stream on channel 1 on its next iteration.
- `c.static_files("/static", ...)` serves the page. Its prefix is separate from `/events`, so
  the static middleware does not shadow the stream route.
- Heartbeats (`: ping` comments) keep idle streams alive and detect dead clients. The default
  interval is 15 seconds.

The bounds are described in [the SSE design](../../docs/design/app-api.md#v05-design-server-sent-events).
