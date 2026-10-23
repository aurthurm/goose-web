import src.app.context;
import src.app.routes;
import src.app.params;
import src.app.templates;
import std;
namespace web;

// Global-namespace entry points for the app DSL. Goose resolves c.x(...) (UFCS) in the
// caller's namespace, so application code in the global namespace can only reach these
// names. Each forwards to the web:: implementation, which keeps its helpers private to
// the namespace. Forwarders take the block as a generic function value, unchanged.

fn ::routes<F>(c: web::Ctx&) { web::routes(c, F); }
fn ::group<F>(c: web::Ctx&, prefix: const u8[:]) { web::group(c, prefix, F); }
fn ::get<F>(c: web::Ctx&, pattern: const u8[:]) { web::get(c, pattern, F); }
fn ::post<F>(c: web::Ctx&, pattern: const u8[:]) { web::post(c, pattern, F); }
fn ::put<F>(c: web::Ctx&, pattern: const u8[:]) { web::put(c, pattern, F); }
fn ::patch<F>(c: web::Ctx&, pattern: const u8[:]) { web::patch(c, pattern, F); }
fn ::delete<F>(c: web::Ctx&, pattern: const u8[:]) { web::delete(c, pattern, F); }
fn ::head<F>(c: web::Ctx&, pattern: const u8[:]) { web::head(c, pattern, F); }
fn ::options<F>(c: web::Ctx&, pattern: const u8[:]) { web::options(c, pattern, F); }
fn ::any<F>(c: web::Ctx&, pattern: const u8[:]) { web::any(c, pattern, F); }
fn ::host<F>(c: web::Ctx&, pattern: const u8[:]) { web::host(c, pattern, F); }

fn ::method(c: web::Ctx&) -> const u8[:] { return web::method(c); }
fn ::target(c: web::Ctx&) -> const u8[:] { return web::target(c); }
fn ::path(c: web::Ctx&) -> const u8[:] { return web::path(c); }
fn ::header(c: web::Ctx&, name: const u8[:]) -> const u8[:] { return web::header(c, name); }
fn ::param(c: web::Ctx&, name: const u8[:]) -> const u8[:] { return web::param(c, name); }
fn ::param_int(c: web::Ctx&, name: const u8[:]) -> i64, bool { return web::param_int(c, name); }
fn ::param_u64(c: web::Ctx&, name: const u8[:]) -> u64, bool { return web::param_u64(c, name); }
fn ::param_uuid(c: web::Ctx&, name: const u8[:]) -> u8[..36], bool { return web::param_uuid(c, name); }
fn ::param_slug(c: web::Ctx&, name: const u8[:]) -> u8[..64], bool { return web::param_slug(c, name); }
fn ::peer(c: web::Ctx&) -> const u8[:] { return web::peer(c); }
fn ::query(c: web::Ctx&, key: const u8[:]) -> web::QueryValue { return web::query(c, key); }
fn ::query_int(c: web::Ctx&, key: const u8[:], fallback: i64) -> i64, bool { return web::query_int(c, key, fallback); }
// Typed query binding: query<Filter>(c) -> Filter, bool; query_result<Filter>(c) also returns the DecodeResult.
fn ::query<T>(c: web::Ctx&) -> T, bool { return web::query<T>(c); }
fn ::query_result<T>(c: web::Ctx&) -> T, web::DecodeResult { return web::query_result<T>(c); }
fn ::status(c: web::Ctx&, code: i32) -> web::Ctx& { return web::status(c, code); }
fn ::set(c: web::Ctx&, name: const u8[:], value: const u8[:]) -> web::Ctx& { return web::set(c, name, value); }
fn ::text(c: web::Ctx&, body: const u8[:]) { web::text(c, body); }
fn ::html(c: web::Ctx&, body: const u8[:]) { web::html(c, body); }
fn ::json_raw(c: web::Ctx&, body: const u8[:]) { web::json_raw(c, body); }
fn ::no_content(c: web::Ctx&) { web::no_content(c); }
fn ::redirect(c: web::Ctx&, location: const u8[:], code: i32 = web::HTTP_FOUND) { web::redirect(c, location, code); }
fn ::fail(c: web::Ctx&, code: i32, error_code: const u8[:], message: const u8[:]) { web::fail(c, code, error_code, message); }
fn ::done(c: web::Ctx&) -> bool { return web::done(c); }
// Server-sent events: c.sse(channel) upgrades the connection; web::sse_publish(control, channel, event, data) sends.
fn ::sse(c: web::Ctx&, channel: i32) -> bool { return web::sse(c, channel); }

// Responses and bodies. c.json takes a struct or scalar by value; c.json_list takes an
// array or slice. c.body<T>() writes 415/400/422 and returns false on failure.
fn ::json<T>(c: web::Ctx&, value: T) { web::json(c, value); }
fn ::json_list<E>(c: web::Ctx&, items: E[:]) { web::json_list(c, items); }
fn ::body<T>(c: web::Ctx&) -> T, bool { return web::body<T>(c); }
fn ::body_result<T>(c: web::Ctx&) -> T, web::DecodeResult { return web::body_result<T>(c); }

// Form bodies: form<Form>(c) -> Form, bool. A wrong media type writes 415, a bad pair 400 invalid_form.
fn ::form<T>(c: web::Ctx&) -> T, bool { return web::form<T>(c); }

// Templates (see docs/api.md#templates). c.html_template(embed_file("views/x.html"), data) writes text/html.
fn ::html_template<T>(c: web::Ctx&, template: const u8[:], data: T) { web::html_template(c, template, data); }
fn ::check_template<T>(template: const u8[:]) -> bool, u8[>..] { return web::check_template<T>(template); }
fn ::html_escape(out: u8[>..]&, text: const u8[:]) { web::html_escape(out, text); }

// Middleware. Each takes the block as Next; c.name() { ... } and web::name(c) { ... } agree.
fn ::request_id<F>(c: web::Ctx&) { web::request_id(c, F); }
fn ::logger<F>(c: web::Ctx&) { web::logger(c, F); }
fn ::cors<F>(c: web::Ctx&, origin: const u8[:] = "*") { web::cors(c, origin, F); }
fn ::require_json<F>(c: web::Ctx&) { web::require_json(c, F); }
fn ::static_files<F>(c: web::Ctx&, url_prefix: const u8[:], directory: const u8[:]) { web::static_files(c, url_prefix, directory, F); }
fn ::rate_limit<F>(c: web::Ctx&, limit: i64, window_ms: i64) { web::rate_limit(c, limit, window_ms, F); }
fn ::secure_headers<F>(c: web::Ctx&, content_security_policy: const u8[:] = "default-src 'self'", hsts: const u8[:] = "") {
    web::secure_headers(c, content_security_policy, hsts, F);
}

// Cookies. c.cookie(name) reads the request; c.set_cookie(name, value, opts) returns false when
// the name, value or options are invalid (nothing is set in that case).
fn ::cookie(c: web::Ctx&, name: const u8[:]) -> const u8[:] { return web::cookie(c, name); }
fn ::set_cookie(c: web::Ctx&, name: const u8[:], value: const u8[:], opts: web::CookieOptions = web::CookieOptions { .. }) -> bool {
    return web::set_cookie(c, name, value, opts);
}

// OpenAPI. web::openapi(c, info) { c.routes() { ... } } serves the document; annotations
// are no-ops except in the describe pass. Generic type arguments need the web:: form.
fn ::openapi<F>(c: web::Ctx&, info: web::OpenApiInfo) { web::openapi(c, info, F); }
fn ::summary(c: web::Ctx&, text: const u8[:]) { web::summary(c, text); }
fn ::tag(c: web::Ctx&, name: const u8[:]) { web::tag(c, name); }
fn ::accepts<T>(c: web::Ctx&) { web::accepts<T>(c); }
fn ::returns<T>(c: web::Ctx&, status: i32) { web::returns<T>(c, status); }
fn ::returns_list<T>(c: web::Ctx&, status: i32) { web::returns_list<T>(c, status); }
fn ::returns_empty(c: web::Ctx&, status: i32) { web::returns_empty(c, status); }
fn ::query_params<T>(c: web::Ctx&) { web::query_params<T>(c); }
