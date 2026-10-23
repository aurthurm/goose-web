import goose_web from "../..";
import todo_app from "./todos";
import std;

// Domain and request events share one bounded bus. Topics are plain constants.
const REQUEST_HANDLED = 1;
const SERVER_LIFECYCLE = 2;
const TODO_CHANGED = 3;
// A mutation reserves one slot for its domain event and one for the request event.
const MUTATION_EVENT_SLOTS = 2;
struct AppEvent { status: i32, request_id: i64, stage: i32, action: i32, todo_id: i64 }
struct Health { status: u8[..8] }

var events = web::event_bus<AppEvent>();
var control = default<web::ServerControl>();
var first_listener: i64 = web::INVALID_SUBSCRIPTION;
var requests_listener: i64 = web::INVALID_SUBSCRIPTION;
var lifecycle_listener: i64 = web::INVALID_SUBSCRIPTION;
var todo_listener: i64 = web::INVALID_SUBSCRIPTION;
var observed_requests: i64 = 0;

fn can_mutate() -> bool {
    // The reactor cannot interleave another callback while a handler runs, so
    // capacity checked here is still available when the mutation publishes.
    return events.count <= web::MAX_QUEUED_EVENTS - MUTATION_EVENT_SLOTS;
}

fn on_mutation(request_id: i64, action: i32, id: i64) {
    assert(web::dispatch(events, TODO_CHANGED,
        AppEvent { status: 0, request_id: request_id, stage: 0, action: action, todo_id: id }));
}

// Publishes one event per completed response. A full queue turns the response into 503,
// which is why mutations reserve capacity before they change any state.
fn publish_request<Next>(c: web::Ctx&) {
    Next();
    if !web::dispatch(events, REQUEST_HANDLED,
        AppEvent { status: c.response.status, request_id: c.request_id, stage: 0, action: 0, todo_id: 0 }) {
        c.fail(web::HTTP_SERVICE_UNAVAILABLE, "event_queue_full", "Required event queue is full");
    }
}

fn app(c: web::Ctx&) {
    request_id(c) { c.logger() { publish_request(c) {
        c.routes() {
            c.get("/health") { c.json(Health { status: "ok" }); };
            todo::mount(c, can_mutate, on_mutation);
        };
    }}};
}

fn tick() {
    web::drain(events) { subscription, event =>
        if subscription == requests_listener { observed_requests += 1; }
        if subscription == first_listener { print("first request handled"); }
        if subscription == lifecycle_listener { print("server lifecycle stage=", event.args.stage); }
        if subscription == todo_listener { print("todo action=", event.args.action, " id=", event.args.todo_id); }
    };
}

fn lifecycle(stage: i32, stats: web::ServerStats) {
    if !web::dispatch(events, SERVER_LIFECYCLE,
        AppEvent { status: 0, request_id: 0, stage: stage, action: 0, todo_id: 0 }) {
        print("lifecycle event queue full");
    }
    if stage == web::SERVER_STOPPED {
        print("observed=", observed_requests, " completed=", stats.completed, " rejected=", stats.rejected, " timeouts=", stats.timeouts);
    }
}

fn main() {
    let argv = args();
    if argv.len > 4 { abort("usage: server [port] [max-responses] [data-file|--memory]"); }
    var config = web::server_config();
    if argv.len > 1 {
        let value, ok = parse_int(argv[1]);
        if !ok || value < web::MIN_PORT || value > web::MAX_PORT { abort("invalid port"); }
        config.port = value as i32;
    }
    if argv.len > 2 {
        let value, ok = parse_int(argv[2]);
        if !ok || value < web::UNLIMITED_REQUESTS { abort("invalid request limit"); }
        config.max_requests = value;
    }
    let path = if argv.len > 3 { argv[3] } else { todo::DEFAULT_DATA_FILE };
    if !todo::setup(if path == todo::MEMORY_OPTION { "" } else { path }) {
        abort("cannot initialize todo store: invalid file, inaccessible data, or path too long");
    }
    requests_listener = web::subscribe(events, REQUEST_HANDLED);
    first_listener = web::subscribe(events, REQUEST_HANDLED, true);
    lifecycle_listener = web::subscribe(events, SERVER_LIFECYCLE);
    todo_listener = web::subscribe(events, TODO_CHANGED);
    config.handle_signals = true;
    print("Goose Todo API listening on http://127.0.0.1:", config.port);
    if !web::run_with(config, control, app, tick, lifecycle) { abort("server transport failed"); }
    tick();
}
