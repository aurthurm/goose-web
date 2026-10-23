import goose_web from "../..";
import std;
import os;

// Larger than the old 8 KiB inline cap and smaller than the 64 KiB ceiling.
const BIG_BODY_BYTES = 61440;

var control = default<web::ServerControl>();
var stages: i64 = 0;
fn lifecycle(stage: i32, stats: web::ServerStats) {
    stages = stages * 10 + stage;
    if stage == web::SERVER_STOPPED { assert(stats.active == 0 && !control.running); }
}
fn tick() {}
fn handle(request: web::Request, response: web::Response&) {
    if request.target == "/big" {
        for i in BIG_BODY_BYTES { response.body.push((i % 251) as! u8); }
        return;
    }
    // Echoing the target lets pipelined tests check response order.
    response.body = request.target;
    if request.target == "/stop" { web::request_shutdown(control); }
}
fn main() {
    let argv = args();
    var config = web::server_config();
    assert(web::validate_server_config(config));
    config.port = 0;
    assert(!web::serve_config(config, control, handle, tick, lifecycle));
    assert(stages == 0 && !control.running);
    config = web::server_config();
    config.max_clients = 65;
    assert(!web::validate_server_config(config));
    config.max_clients = 1;
    config.max_request_bytes = 8193;
    assert(!web::validate_server_config(config));
    config.max_request_bytes = 128;
    config.read_timeout_ms = 0;
    assert(!web::validate_server_config(config));
    config.read_timeout_ms = 200;
    config.write_timeout_ms = 0;
    assert(!web::validate_server_config(config));
    config.write_timeout_ms = 1000;
    config.shutdown_grace_ms = -1;
    assert(!web::validate_server_config(config));
    config.shutdown_grace_ms = 400;
    config.idle_timeout_ms = 0;
    assert(!web::validate_server_config(config));
    config.idle_timeout_ms = 5000;
    config.max_response_bytes = 0;
    assert(!web::validate_server_config(config));
    config.max_response_bytes = web::MAX_RESPONSE_BODY_BYTES + 1;
    assert(!web::validate_server_config(config));
    config.max_response_bytes = web::MAX_RESPONSE_BODY_BYTES;
    config.max_requests_per_connection = -1;
    assert(!web::validate_server_config(config));
    config.max_requests_per_connection = web::MAX_REQUESTS_PER_CONNECTION + 1;
    assert(!web::validate_server_config(config));
    config.max_requests_per_connection = 0;
    assert(web::validate_server_config(config));
    let port, valid = parse_int(argv[1]);
    assert(valid);
    config.port = port as i32;
    config.max_clients = 2;
    config.handle_signals = true;
    if argv[2] == "deadline" { config.read_timeout_ms = 20; config.poll_timeout_ms = 1000; }
    if argv[2] == "finite" { config.max_requests = 1; }
    if argv[2] == "grace" { config.read_timeout_ms = 5000; }
    if argv[2] == "perconn" { config.max_requests_per_connection = 2; }
    if argv[2] == "idle" { config.idle_timeout_ms = 150; }
    if argv[2] == "capped" { config.max_response_bytes = 1024; }
    if argv[2] == "http1only" { config.keep_alive = false; }
    assert(web::serve_config(config, control, handle, tick, lifecycle));
    assert(stages == 123);
    assert(control.stats.active == 0);
    print("STATS ", control.stats.accepted, " ", control.stats.completed, " ",
        control.stats.rejected, " ", control.stats.timeouts, " ", control.stats.forced_closes,
        " ", control.stats.bytes_read, " ", control.stats.bytes_written, " ", control.stats.reused);
}
