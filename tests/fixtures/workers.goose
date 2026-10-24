import goose_web from "../..";
import std;
import os;

// Pre-forked workers: usage `workers PORT`, with the worker count from GOOSE_WEB_WORKERS. /pid names the serving process, /crash aborts
// the worker that takes it, and the parent prints one STATS line when the server has stopped.
var control = default<web::ServerControl>();

fn tick() {}

fn lifecycle(stage: i32, stats: web::ServerStats) {
    if stage == web::SERVER_STOPPED {
        print("STATS ", stats.accepted, " ", stats.completed, " ", stats.rejected, " ", stats.forced_closes,
            " ", stats.active, " ", stats.bytes_written);
    }
}

fn app(c: web::Ctx&) {
    request_id(c) { c.logger() {
        c.routes() {
            c.get("/health") { c.text("ok"); };
            c.get("/pid") { c.text(str(web::process_id())); };
            c.get("/crash") { abort("worker crash requested by the test"); };
        };
    }};
}

fn main() {
    let argv = args();
    let port, port_ok = parse_int(argv[1]);
    assert(port_ok);
    let config, ok, message = web::config_from_env();
    if !ok { abort(message[..]); }
    config.port = port as i32;
    config.shutdown_grace_ms = 2000;
    let started = web::run_with(config, control, app, tick, lifecycle);
    if !started { abort("server failed"); }
}
