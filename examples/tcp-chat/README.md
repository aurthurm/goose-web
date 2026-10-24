# TCP chat

A line-based chat room over TCP. Each line is a message to the other members. The room uses
`web::TcpFrame` for per-connection line buffers, `web::tcp_conn_at` to walk the members, and
`web::tcp_send` to broadcast.

Commands:

- `/nick NAME` changes your name (up to 15 bytes). New members start as `guestN`.
- `/quit` leaves the room.

A line over 511 bytes closes the connection.

## Run

From the repository root:

```sh
goose build examples/tcp-chat/server.goose -o build/tcp-chat
build/tcp-chat 9100
```

The room holds 64 members.

## Try it

Open two terminals:

```sh
nc 127.0.0.1 9100
/nick alice
hi there
```

```sh
nc 127.0.0.1 9100
/nick bob
```

Each message appears in the other terminal as `alice: hi there`. Joining and leaving post
`* name joined` and `* name left` to the rest of the room.
