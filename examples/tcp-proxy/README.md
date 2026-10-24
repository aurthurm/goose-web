# TCP proxy

Accepts clients on one port and opens one upstream connection per client, then pipes bytes both ways.
It shows the client side of the TCP layer (`web::tcp_connect`), connection tags to tell the two sides
apart, and backpressure in both directions: a client is not read while its upstream queue is above
the high-water mark, and the upstream is not read while the client's queue is.

The upstream address must be numeric (`127.0.0.1`, `::1`). Names are not resolved.

## Run

From the repository root, start an upstream and the proxy in two terminals. The upstream here is the
echo example:

```sh
goose build examples/tcp-echo/server.goose -o build/tcp-echo
goose build examples/tcp-proxy/server.goose -o build/tcp-proxy
build/tcp-echo 9001
build/tcp-proxy 9000 127.0.0.1 9001
```

The proxy prints `tcp proxy 9000 -> 127.0.0.1:9001` and listens on 127.0.0.1 port 9000.

## Try it

```sh
nc 127.0.0.1 9000
through the proxy
through the proxy
```

If the upstream is not running, the proxy closes the client as soon as its upstream connect fails.
Like any TCP close with unread input, the client may see a reset rather than end of stream.
