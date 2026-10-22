// Native readiness-driven event loop proof of concept.
// Still not an RFC-complete HTTP server. Loopback only.
import std;

extern fn gw_reactor_start(port: i32) -> i32;
extern fn gw_reactor_poll(timeout_ms: i32) -> i32;
extern fn gw_reactor_take(token: i32, data: u8[:]) -> i64;
extern fn gw_reactor_reply(token: i32, data: const u8[:]) -> i32;

fn main() {
    assert(gw_reactor_start(8000) == 0);
    print("Goose Web async reactor prototype listening on 127.0.0.1:8000");
    loop {
        let token = gw_reactor_poll(25);
        if token <= 0 { continue; }
        var bytes: u8[..8192] = [];
        for i in 8192 { bytes.push(0); }
        let n = gw_reactor_take(token, bytes);
        if n < 0 { continue; }
        let payload = if n>=6 && bytes[..6]=="GET / " {
            "{\"message\":\"Hello from Goose Web reactor\"}"
        } else {
            "{\"status\":\"ok\"}"
        };
        let response = str("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n",
                           "Connection: close\r\nContent-Length: ",payload.len,"\r\n\r\n",payload);
        assert(gw_reactor_reply(token,response)==0);
    }
}
