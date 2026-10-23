import src.constants.runtime;
import src.http.request;
import src.http.response;
import src.runtime.server;
import src.app.context;
import std;
namespace web;

fn run_tick() {}

// Builds one Ctx per request around the server's request view. The app writes into
// c.response, and the finished response is copied back in one piece.
fn handle_app<App>(request: Request, out: Response&) {
    // App arrives as a trailing function argument; a type argument cannot name it.
    // Pass &c: an untyped block parameter would receive a copy of this fixed-size Ctx,
    // and every response write would land in that copy.
    var c = new_ctx(request);
    App(&c);
    out = c.response;
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
