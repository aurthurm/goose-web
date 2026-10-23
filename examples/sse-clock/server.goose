import goose_web from "../..";
import std;
import os;

// Server-sent events clock. The tick publishes the UTC time on channel 1 once per second. Browsers
// subscribe at /events; the page is served from /static/ (see public/index.html).
// Run from the repository root so the static directory resolves:
//   build/sse_clock --port 8080      then open http://127.0.0.1:8080/static/

const CLOCK_CHANNEL = 1;
const NANOSECONDS_PER_SECOND = 1000000000;

var control = default<web::ServerControl>();
var last_second: i64 = -1;

// Two decimal digits, zero padded.
fn two_digits(out: u8[>..]&, n: i64) {
    out.push('0' + ((n / 10) % 10) as! u8);
    out.push('0' + (n % 10) as! u8);
}

// Publishes once per wall-clock second. The reactor sends the event on its next iteration.
fn tick() {
    let seconds = time_ns() / NANOSECONDS_PER_SECOND;
    if seconds == last_second { return; }
    last_second = seconds;
    var text: u8[>..] = [];
    two_digits(text, (seconds / 3600) % 24);
    text.append(":");
    two_digits(text, (seconds / 60) % 60);
    text.append(":");
    two_digits(text, seconds % 60);
    web::sse_publish(control, CLOCK_CHANNEL, "time", text[..]);
}

fn app(c: web::Ctx&) {
    c.logger() {
        c.static_files("/static", "examples/sse-clock/public") {
            c.routes() {
                c.get("/events") { c.sse(CLOCK_CHANNEL); };
            };
        };
    };
}

fn main() {
    let config, ok, error = web::config_from_args(args());
    if !ok { abort(error); }
    var settings = config;
    settings.handle_signals = true;
    print("SSE clock on port ", settings.port, ": open /static/ in a browser, Ctrl+C to stop");
    let started = web::run_with(settings, control, app, tick, web::ignore_lifecycle);
    if !started { abort("server failed"); }
}
