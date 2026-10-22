// Bootstrap-only HTTP hello world; synchronous POSIX transport.
// Do not expose this demo directly to the internet.
import std;
import web from "..";

extern fn gw_listen(port: i32) -> i32;
extern fn gw_accept(listener: i32) -> i32;
extern fn gw_read(client: i32, data: u8[:]) -> i64;
extern fn gw_write(client: i32, data: const u8[:]) -> i64;
extern fn gw_close(fd: i32);

fn reply(client: i32, status: i32, body: u8[:]) {
    let msg = str("HTTP/1.1 ", status, " ", status_reason(status), "\r\n",
                  "Content-Type: application/json; charset=utf-8\r\n",
                  "Connection: close\r\n",
                  "X-Content-Type-Options: nosniff\r\n",
                  "Content-Length: ", body.len, "\r\n\r\n", body);
    var sent: i64 = 0;
    while sent < msg.len {
        let n = gw_write(client, msg[sent..]);
        if n <= 0 { break; }
        sent += n;
    }
}

fn main() {
    let listener = gw_listen(8000);
    assert(listener >= 0);
    print("goose-web experimental demo: http://127.0.0.1:8000");
    loop {
        let client = gw_accept(listener);
        if client < 0 { continue; }
        var buffer: u8[..8192] = [];
        for i in 8192 { buffer.push(0); }
        let n = gw_read(client, buffer);
        if n <= 0 { gw_close(client); continue; }
        let request = buffer[..n];
        // Bootstrap: accept only complete header-only GET requests in a single read.
        let lineend = find(request, "\r\n");
        if lineend < 0 {
            reply(client, 400, "{\"error\":\"bad request\"}");
        } else {
            let line = request[..lineend];
            if line == "GET /health HTTP/1.1" {
                reply(client, 200, "{\"status\":\"ok\"}");
            } else if line == "GET / HTTP/1.1" {
                reply(client, 200, "{\"message\":\"Hello from Goose Web\"}");
            } else {
                reply(client, 404, "{\"error\":\"not found\"}");
            }
        }
        gw_close(client);
    }
}
