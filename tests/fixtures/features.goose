import goose_web from "../..";
import std;
import os;

const REQUEST_HANDLED = 1;
const SERVER_LIFECYCLE = 2;
const ROUTE_HEALTH = 1;
const ROUTE_ECHO = 2;
const ROUTE_GREETING = 3;
const ROUTE_USER = 4;
const ROUTE_NEW_USER = 5;
struct AppEvent { status: i32, request_id: i64, stage: i32 }
var events = web::event_bus<AppEvent>();
var routes = web::router();
var control = default<web::ServerControl>();
var request_listener: i64 = web::INVALID_SUBSCRIPTION;
var counter_listener: i64 = web::INVALID_SUBSCRIPTION;
var first_listener: i64 = web::INVALID_SUBSCRIPTION;
var lifecycle_listener: i64 = web::INVALID_SUBSCRIPTION;
var request_id: i64 = 0;
var observed_requests: i64 = 0;

fn on_event_overflow(response: web::Response&) {
    // Required request events: preserve explicit backpressure with a 503.
    web::application_error(response, web::HTTP_SERVICE_UNAVAILABLE, "event_queue_full", "Event queue full");
}

fn before_request(request: web::Request, response: web::Response&) -> bool {
    request_id += 1;
    assert(web::set_header(response, web::HEADER_REQUEST_ID, str(request_id)));
    // A visible, testable short-circuit example; this is not authentication.
    if web::request_header(request, "X-Demo-Reject") == "yes" {
        web::application_error(response, web::HTTP_FORBIDDEN, "request_rejected", "Request rejected by example middleware");
        return false;
    }
    return true;
}

fn route_request(request: web::Request, response: web::Response&) {
    let matched = web::match_route(routes, request.method, request.target);
    if matched.status == web::HTTP_NOT_FOUND {
        web::application_error(response, web::HTTP_NOT_FOUND, "not_found", "Route not found");
        return;
    }
    if matched.status == web::HTTP_METHOD_NOT_ALLOWED {
        assert(web::set_header(response, web::HEADER_ALLOW, matched.allow));
        web::application_error(response, web::HTTP_METHOD_NOT_ALLOWED, "method_not_allowed", "Method not allowed for this route");
        return;
    }
    match matched.handler_id {
        ROUTE_HEALTH => {
            response.content_type = web::CONTENT_TYPE_JSON;
            web::set_body(response, "{\"status\":\"ok\"}\n");
        },
        ROUTE_ECHO => { web::set_body(response, request.body); },
        ROUTE_GREETING => {
            let name = web::query_value(request.target, "name");
            if name.status == web::HTTP_BAD_REQUEST || name.status == web::HTTP_CONTENT_TOO_LARGE {
                web::application_error(response, name.status, "invalid_query", "Query could not be decoded within its limit");
            } else {
                web::set_body(response, "Hello, ");
                if name.status == web::HTTP_OK { web::append_body(response, name.value); }
                else { web::append_body(response, "Goose"); }
                web::append_body(response, "!\n");
            }
        },
        ROUTE_USER => { web::set_body(response, web::path_param(matched, "id")); },
        ROUTE_NEW_USER => { web::set_body(response, "New user form\n"); },
        _ => { web::application_error(response, web::HTTP_INTERNAL_SERVER_ERROR, "unknown_handler", "Route handler is unavailable"); }
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
    var port: i32 = web::DEFAULT_PORT;
    var limit: i64 = web::UNLIMITED_REQUESTS;
    if argv.len > 1 {
        let value, ok = parse_int(argv[1]);
        if !ok || value < web::MIN_PORT || value > web::MAX_PORT { abort("invalid port"); }
        port = value as i32;
    }
    if argv.len > 2 {
        let value, ok = parse_int(argv[2]);
        if !ok || value < web::UNLIMITED_REQUESTS { abort("invalid request limit"); }
        limit = value;
    }
    assert(web::add_route(routes, web::METHOD_GET, "/health", ROUTE_HEALTH));
    assert(web::add_route(routes, web::METHOD_POST, "/echo", ROUTE_ECHO));
    assert(web::add_route(routes, web::METHOD_GET, "/greet", ROUTE_GREETING));
    assert(web::add_route(routes, web::METHOD_GET, "/users/:id", ROUTE_USER));
    assert(web::add_route(routes, web::METHOD_GET, "/users/new", ROUTE_NEW_USER));
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
