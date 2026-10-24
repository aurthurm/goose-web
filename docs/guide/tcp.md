# Custom TCP protocols

**Version:** The custom TCP API is on `main` and is not in the published `v0.6.0` package. The code
below is a partial echo pattern; use the linked example for imports and all event cases.

Use the TCP API for a custom protocol that needs nonblocking socket I/O. `web::tcp_serve` runs a
separate reactor from HTTP; a process can run only one TCP loop and one HTTP reactor, but they do
not share one event loop. TCP has no pre-fork worker mode. Handlers and `tick` run synchronously on
the TCP loop, so keep them quick.

```goose
import goose_web from "../goose-web";
import std;
import os;

var control = default<web::TcpControl>();
fn tick() {}
fn on_event(net: web::TcpControl&, ev: web::TcpEvent) {
    match ev {
        Data d => { if !web::tcp_send(net, d.conn, d.bytes) { web::tcp_close(net, d.conn); } },
        _ => {},
    }
}
fn main() {
    var config = web::tcp_config();
    config.port = 7000;
    config.handle_signals = true;
    if !web::tcp_serve(config, control, on_event, tick) { abort("TCP server failed"); }
}
```

Build and run the echo server from the repository root:

```sh
mkdir -p build
goose build examples/tcp-echo/server.goose -o build/tcp-echo
./build/tcp-echo
nc 127.0.0.1 9000
```

This is a partial echo pattern; it assumes the `web` import and the `TcpEvent` cases from the
complete [TCP echo example](../../examples/tcp-echo/server.goose). TCP peer addresses are numeric.
`tcp_connect` accepts IPv4/IPv6 literals only; DNS lookup would block the loop, so resolve names
before entering it.

Write queues are bounded. Check `tcp_send`; use `tcp_pause_reads` and `Writable` events to apply
backpressure, especially in proxies. The provided line and length-prefixed helpers preserve
partial frames across reads and enforce explicit size caps. TCP shutdown flushes queued writes,
sends FIN and allows peers to close until the grace period expires.

There is no UDP or TLS support in this API. See [TCP API](../api.md#tcp-servers-and-clients) and
the [TCP proxy example](../../examples/tcp-proxy/README.md) for upstream flow control.
