import goose_web from "../..";
import std;
import os;

// Pre-forked workers: usage `workers PORT [RESTART_BUDGET]`, with the worker count from GOOSE_WEB_WORKERS.
// /pid names the serving process, /crash aborts the worker that takes it, and /block holds its worker
// for 30 seconds (so the shutdown grace must expire). The parent prints one STATS line when the server
// has stopped. RESTART_BUDGET, when given, replaces ServerConfig.worker_restart_budget.
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
            // Short sleeps: SIGTERM can interrupt one sleep, and the rest of the 30 seconds must still hold.
            c.get("/block") { for i in 300 { sleep_ms(100); } c.text("late"); };
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
    if argv.len > 2 {
        let budget, budget_ok = parse_int(argv[2]);
        assert(budget_ok);
        config.worker_restart_budget = budget;
    }
    let started = web::run_with(config, control, app, tick, lifecycle);
    if !started { exit(1); }
}
