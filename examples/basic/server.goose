import goose_web from "../..";
import todo_app from "./todos";
import std;
import os;

const REQUEST_HANDLED = 1;
const SERVER_LIFECYCLE = 2;
const TODO_CHANGED = 3;
const MUTATION_EVENT_SLOTS = 2;
struct AppEvent { status: i32, request_id: i64, stage: i32, action: i32, todo_id: i64 }
var events = web::event_bus<AppEvent>();
var control = default<web::ServerControl>();
var request_listener: i64 = web::INVALID_SUBSCRIPTION;
var counter_listener: i64 = web::INVALID_SUBSCRIPTION;
var first_listener: i64 = web::INVALID_SUBSCRIPTION;
var lifecycle_listener: i64 = web::INVALID_SUBSCRIPTION;
var todo_listener: i64 = web::INVALID_SUBSCRIPTION;
var request_id: i64 = 0;
var observed_requests: i64 = 0;

fn before_request(request: web::Request, response: web::Response&) -> bool {
    request_id += 1;
    assert(web::set_header(response, web::HEADER_REQUEST_ID, str(request_id)));
    return true;
}

fn can_mutate() -> bool {
    // Reserve one domain event and the request event before any file/state write.
    // The reactor cannot interleave another callback while a handler is running.
    return events.count <= web::MAX_QUEUED_EVENTS - MUTATION_EVENT_SLOTS;
}

fn on_mutation(action: i32, id: i64) {
    assert(web::dispatch(events, TODO_CHANGED,
        AppEvent { status: 0, request_id: request_id, stage: 0, action: action, todo_id: id }));
}

fn route_request(request: web::Request, response: web::Response&) {
    todo::handle(request, response, can_mutate, on_mutation);
}

fn after_request(request: web::Request, response: web::Response&) {
    if !web::dispatch(events, REQUEST_HANDLED,
        AppEvent { status: response.status, request_id: request_id, stage: 0, action: 0, todo_id: 0 }) {
        web::application_error(response, web::HTTP_SERVICE_UNAVAILABLE, "event_queue_full", "Required event queue is full");
    }
}

fn handle(request: web::Request, response: web::Response&) {
    web::pipeline(request, response, before_request, route_request, after_request);
}

fn tick() {
    web::drain(events) { subscription, event =>
        if subscription == request_listener { print("request ", event.args.request_id, " status=", event.args.status); }
        if subscription == counter_listener { observed_requests += 1; }
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
        print("completed=", stats.completed, " rejected=", stats.rejected, " timeouts=", stats.timeouts);
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
    request_listener = web::subscribe(events, REQUEST_HANDLED);
    counter_listener = web::subscribe(events, REQUEST_HANDLED);
    first_listener = web::subscribe(events, REQUEST_HANDLED, true);
    lifecycle_listener = web::subscribe(events, SERVER_LIFECYCLE);
    todo_listener = web::subscribe(events, TODO_CHANGED);
    config.handle_signals = true;
    print("Goose Todo API listening on http://127.0.0.1:", config.port);
    if !web::serve_config(config, control, handle, tick, lifecycle) { abort("server transport failed"); }
    tick();
}
