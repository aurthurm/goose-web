import goose_web from "../..";
import std;
import os;

const REQUEST_HANDLED = 1;
const SERVER_LIFECYCLE = 2;
struct AppEvent { status: i32, request_id: i64, stage: i32 }
var events = web::event_bus<AppEvent>();
var routes = web::router();
var control = default<web::ServerControl>();
var request_listener: i64 = 0;
var counter_listener: i64 = 0;
var first_listener: i64 = 0;
var lifecycle_listener: i64 = 0;
var request_id: i64 = 0;
var observed_requests: i64 = 0;

fn on_event_overflow(response: web::Response&) {
    // Required request events: preserve explicit backpressure with a 503.
    web::application_error(response, 503, "event_queue_full", "Event queue full");
}

fn before_request(request: web::Request, response: web::Response&) -> bool {
    request_id += 1;
    assert(web::set_header(response, "X-Request-ID", str(request_id)));
    // A visible, testable short-circuit example; this is not authentication.
    if web::request_header(request, "X-Demo-Reject") == "yes" {
        web::application_error(response, 403, "request_rejected", "Request rejected by example middleware");
        return false;
    }
    return true;
}

fn route_request(request: web::Request, response: web::Response&) {
    let matched = web::match_route(routes, request.method, request.target);
    if matched.status == 404 {
        web::application_error(response, 404, "not_found", "Route not found");
        return;
    }
    if matched.status == 405 {
        assert(web::set_header(response, "Allow", matched.allow));
        web::application_error(response, 405, "method_not_allowed", "Method not allowed for this route");
        return;
    }
    match matched.handler_id {
        1 => {
            response.content_type = "application/json";
            response.body = "{\"status\":\"ok\"}\n";
        },
        2 => { response.body = request.body; },
        3 => {
            let name = web::query_value(request.target, "name");
            if name.status == 400 || name.status == 413 {
                web::application_error(response, name.status, "invalid_query", "Query could not be decoded within its limit");
            } else {
                response.body = "Hello, ";
                if name.status == 200 { response.body.append(name.value); }
                else { response.body.append("Goose"); }
                response.body.append("!\n");
            }
        },
        4 => { response.body = web::path_param(matched, "id"); },
        5 => { response.body = "New user form\n"; },
        _ => { web::application_error(response, 500, "unknown_handler", "Route handler is unavailable"); }
    }
}

fn after_request(request: web::Request, response: web::Response&) {
    if !web::dispatch(events, REQUEST_HANDLED, AppEvent { status: response.status, request_id: request_id, stage: 0 }) {
        on_event_overflow(response);
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
    };
}

fn lifecycle(stage: i32, stats: web::ServerStats) {
    if !web::dispatch(events, SERVER_LIFECYCLE, AppEvent { status: 0, request_id: 0, stage: stage }) {
        print("lifecycle event queue full");
    }
    if stage == web::SERVER_STOPPED {
        print("completed=", stats.completed, " rejected=", stats.rejected, " timeouts=", stats.timeouts);
    }
}

fn main() {
    let argv = args();
    var port: i32 = 8080;
    var limit: i64 = 0;
    if argv.len > 1 {
        let value, ok = parse_int(argv[1]);
        if !ok || value < 1 || value > 65535 { abort("invalid port"); }
        port = value as i32;
    }
    if argv.len > 2 {
        let value, ok = parse_int(argv[2]);
        if !ok || value < 0 { abort("invalid request limit"); }
        limit = value;
    }
    assert(web::add_route(routes, "GET", "/health", 1));
    assert(web::add_route(routes, "POST", "/echo", 2));
    assert(web::add_route(routes, "GET", "/greet", 3));
    assert(web::add_route(routes, "GET", "/users/:id", 4));
    assert(web::add_route(routes, "GET", "/users/new", 5));
    request_listener = web::subscribe(events, REQUEST_HANDLED);
    counter_listener = web::subscribe(events, REQUEST_HANDLED);
    first_listener = web::subscribe(events, REQUEST_HANDLED, true);
    lifecycle_listener = web::subscribe(events, SERVER_LIFECYCLE);
    var config = web::server_config();
    config.port = port;
    config.max_requests = limit;
    config.handle_signals = true;
    print("Goose Web listening on http://127.0.0.1:", port);
    if !web::serve_config(config, control, handle, tick, lifecycle) { abort("server transport failed"); }
    tick();
}
