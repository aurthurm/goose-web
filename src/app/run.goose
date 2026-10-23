import src.constants.runtime;
import src.http.request;
import src.http.response;
import src.runtime.server;
import src.app.context;
import std;
namespace web;

fn run_tick() {}

// The reactor's scratch for routing, session, CSRF and OpenAPI state. Handlers run synchronously
// on the reactor thread, one request at a time, so one scratch serves every request.
var app_scratch: AppScratch;

// Builds one Ctx per request around the server's request view. The app writes into
// out, the runtime's reused response, so nothing is copied back.
fn handle_app<App>(request: Request, out: Response&) {
    // App arrives as a trailing function argument; a type argument cannot name it.
    // Pass &c: an untyped block parameter would receive a copy of this Ctx,
    // and routing state written by the app would land in that copy.
    var c = new_ctx(request, out, app_scratch);
    App(&c);
}

// Wraps serve_config. Tick and Lifecycle are generic function values, as in serve_config.
fn run_with<App, Tick, Lifecycle>(config: ServerConfig, control: ServerControl&) -> bool {
    fn handle(request: Request, out: Response&) { handle_app(request, out, App); }
    return serve_config(config, control, handle, Tick, Lifecycle);
}

// Trailing-block form: web::run(config) { c => app(c) }. Returns false when the
// server cannot start; the app runs synchronously on the reactor thread.
fn run<App>(config: ServerConfig) -> bool {
    var control = default<ServerControl>();
    return run_with(config, control, App, run_tick, ignore_lifecycle);
}
