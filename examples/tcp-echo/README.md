# TCP echo

The smallest custom-protocol server: every byte received goes straight back to the peer. The
handler sends with `web::tcp_send` and closes with `web::tcp_close` if the queue refuses the bytes.

## Run

From the repository root:

```sh
goose build examples/tcp-echo/server.goose -o build/tcp-echo
build/tcp-echo 9000
```

It listens on 127.0.0.1 port 9000 (the default port is 9000 when none is given). Ctrl-C or SIGTERM
drains open connections and exits 0.

## Try it

With netcat:

```sh
nc 127.0.0.1 9000
hello
hello
```

With telnet, the same:

```sh
telnet 127.0.0.1 9000
```

Send a large file to check backpressure and ordering:

```sh
head -c 4000000 /dev/urandom > /tmp/blob && nc -q 2 127.0.0.1 9000 < /tmp/blob | cmp - /tmp/blob && echo same
```

(`nc -q` is the GNU netcat option; use `-N` on OpenBSD netcat, which closes after stdin ends.)
