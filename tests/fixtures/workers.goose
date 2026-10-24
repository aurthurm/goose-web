import goose_web from "../..";
import std;
import os;

// Pre-forked workers: usage `workers PORT [RESTART_BUDGET]`, with the worker count from GOOSE_WEB_WORKERS.
// /pid names the serving process, /crash aborts the worker that takes it, and /block holds its worker
// for 30 seconds (so the shutdown grace must expire). The parent prints one STATS line when the server
// has stopped. RESTART_BUDGET, when given, replaces ServerConfig.worker_restart_budget.
// The shared-store routes: /limited (20 per minute per client, across all workers), /session/set/:value and
// /session/get (server-side sessions), /stream/:channel and /publish/:channel (events across workers).
var control = default<web::ServerControl>();

// The channel of a stream that has just opened: its first event, "hello" carrying this process id, is published
// from the next loop pass, once the stream is registered. That tells the test which worker holds the stream.
var hello_channel: i32 = 0;
var hello_pending = false;

const SESSION_SECRET = "0123456789abcdef0123456789abcdef";

fn tick() {
    if hello_pending {
        hello_pending = false;
        web::sse_publish(control, hello_channel, "hello", str(web::process_id()));
    }
}

fn lifecycle(stage: i32, stats: web::ServerStats) {
    if stage == web::SERVER_STOPPED {
        print("STATS ", stats.accepted, " ", stats.completed, " ", stats.rejected, " ", stats.forced_closes,
            " ", stats.active, " ", stats.bytes_written);
    }
}

fn stored_session() -> web::SessionConfig {
    return web::SessionConfig { secret: SESSION_SECRET, store: true };
}

fn app(c: web::Ctx&) {
    request_id(c) { c.logger() {
        c.routes() {
            c.get("/health") { c.text("ok"); };
            c.get("/pid") { c.text(str(web::process_id())); };
            c.get("/crash") { abort("worker crash requested by the test"); };
            // Short sleeps: SIGTERM can interrupt one sleep, and the rest of the 30 seconds must still hold.
            c.get("/block") { for i in 300 { sleep_ms(100); } c.text("late"); };
            c.get("/limited") { c.rate_limit(20, 60000) { c.text("ok"); }; };
            c.get("/session/set/:value") {
                let value = c.param("value");
                session(c, stored_session()) {
                    assert(session_set(c, "v", value));
                    c.text(str(web::process_id()));
                };
            };
            c.get("/session/get") {
                session(c, stored_session()) {
                    c.text(str(session_get(c, "v"), " ", web::process_id()));
                };
            };
            c.get("/stream/:channel") {
                let channel, ok = c.param_int("channel");
                guard ok else { return; }
                hello_channel = channel as i32;
                hello_pending = true;
                let started = c.sse(channel as i32);
                assert(started);
            };
            c.post("/publish/:channel") {
                let channel, ok = c.param_int("channel");
                guard ok else { return; }
                let subscribers = web::sse_publish(control, channel as i32, "msg", c.request.body);
                c.text(str(web::process_id(), ":", subscribers));
            };
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
