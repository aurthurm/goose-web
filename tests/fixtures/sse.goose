// Server-sent events over real sockets. tests/integration/sse.py drives it with the modes
// "default", "slow" (a small per-stream queue), "limit" (two streams at most) and "beat" (fast heartbeats).
import goose_web from "../..";
import std;
import os;

// Burst messages are big enough that a stream which never reads fills its queue quickly.
const BURST_MESSAGE_BYTES = 60000;
const BURST_PER_TICK = 2;

var control = default<web::ServerControl>();
var burst_channel: i32 = 0;
var burst_left: i64 = 0;
var burst_payload: u8[>..] = [];

fn tick() {
    var sent: i64 = 0;
    while burst_left > 0 && sent < BURST_PER_TICK {
        web::sse_publish(control, burst_channel, "burst", burst_payload[..]);
        burst_left -= 1;
        sent += 1;
    }
}

fn app(c: web::Ctx&) {
    c.routes() {
        c.get("/stream/:channel") {
            let channel, ok = c.param_int("channel");
            guard ok else { return; }
            let started = c.sse(channel as i32);
            assert(started);
        };
        c.post("/publish/:channel") {
            let channel, ok = c.param_int("channel");
            guard ok else { return; }
            // The body is the event data; the event name is fixed to "msg".
            let subscribers = web::sse_publish(control, channel as i32, "msg", c.request.body);
            c.text(str(subscribers));
        };
        c.post("/burst/:channel/:count") {
            let channel, ok = c.param_int("channel");
            guard ok else { return; }
            let count, counted = c.param_int("count");
            guard counted else { return; }
            burst_channel = channel as i32;
            burst_left = count;
            c.text("burst started");
        };
        c.get("/stats") {
            c.text(str("sse_active=", control.stats.sse_active, " sse_sent=", control.stats.sse_sent,
                " sse_dropped=", control.stats.sse_dropped, " connections=", control.stats.active));
        };
        c.get("/plain") { c.text("plain"); };
    };
}

fn main() {
    let argv = args();
    var config = web::server_config();
    let port, valid = parse_int(argv[1]);
    assert(valid);
    config.port = port as i32;
    config.max_clients = 8;
    config.handle_signals = true;
    if argv[2] == "slow" { config.sse_max_queued_bytes = 131072; }
    if argv[2] == "limit" { config.max_sse_clients = 2; }
    if argv[2] == "beat" { config.sse_heartbeat_ms = 100; }
    burst_payload.resize(BURST_MESSAGE_BYTES, 'b');
    assert(web::run_with(config, control, app, tick, web::ignore_lifecycle));
    assert(control.stats.active == 0 && control.stats.sse_active == 0);
    print("sse fixture stopped");
}
