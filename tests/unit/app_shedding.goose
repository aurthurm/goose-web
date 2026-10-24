// Load shedding (policy thresholds with injected pressure, the 503 response) and the per-route body cap.
import goose_web from "../..";
import std;

var shared_response = web::response();
var shared_scratch = web::AppScratch { .. };

fn pressure(active: i64, max_clients: i64, used: i64, max: i64) -> web::ServerPressure {
    return web::ServerPressure { active: active, max_clients: max_clients, pool_bytes_used: used, pool_bytes_max: max,
        queued_events: 0, max_queued_events: 256 };
}

fn make_ctx(method: const u8[:], body: const u8[:]) -> web::Ctx {
    shared_response = web::response();
    return web::new_ctx(web::Request { method: method, target: "/s", body: body, raw_headers: "Host: x\r\n" }, shared_response, shared_scratch);
}

fn header_value(res: web::Response&, name: const u8[:]) -> const u8[:] {
    for i in res.headers.len {
        if res.headers[i].name == name { return res.headers[i].value[..]; }
    }
    return "";
}

fn test_default_policy() {
    let policy = web::LoadPolicy { .. };
    assert(policy.max_active_connections_pct == 90 && policy.max_pool_used_pct == 90 && policy.retry_after_s == 1);
}

// Connections: 89 of 100 is under 90 percent, 90 of 100 is at it.
fn test_connection_threshold() {
    let policy = web::LoadPolicy { .. };
    assert(!web::load_pressure_high(pressure(89, 100, 0, 0), policy));
    assert(web::load_pressure_high(pressure(90, 100, 0, 0), policy));
    assert(web::load_pressure_high(pressure(100, 100, 0, 0), policy));
    // Small limits round the same way: 1 of 8 is 12.5 percent, under 90, and 8 of 8 is over it.
    assert(!web::load_pressure_high(pressure(1, 8, 0, 0), policy));
    assert(web::load_pressure_high(pressure(8, 8, 0, 0), policy));
}

// Pool: 7 of 8 chunks in use is 87.5 percent, under 90; 8 of 8 is over.
fn test_pool_threshold() {
    let policy = web::LoadPolicy { .. };
    assert(!web::load_pressure_high(pressure(0, 64, 7 * 16384, 8 * 16384), policy));
    assert(web::load_pressure_high(pressure(0, 64, 8 * 16384, 8 * 16384), policy));
    let strict = web::LoadPolicy { max_pool_used_pct: 50 };
    assert(web::load_pressure_high(pressure(0, 64, 4 * 16384, 8 * 16384), strict));
    assert(!web::load_pressure_high(pressure(0, 64, 3 * 16384, 8 * 16384), strict));
}

// A percentage of 0 turns its check off. A zero limit (no clients or no pool, as before the first request)
// is never reached.
fn test_disabled_checks() {
    let off = web::LoadPolicy { max_active_connections_pct: 0, max_pool_used_pct: 0 };
    assert(!web::load_pressure_high(pressure(64, 64, 8 * 16384, 8 * 16384), off));
    let only_pool = web::LoadPolicy { max_active_connections_pct: 0 };
    assert(web::load_pressure_high(pressure(0, 64, 8 * 16384, 8 * 16384), only_pool));
    assert(!web::load_pressure_high(pressure(999, 0, 0, 0), web::LoadPolicy { .. }));
    assert(!web::load_pressure_high(web::ServerPressure { .. }, web::LoadPolicy { .. }));
}

fn test_shed_503_with_retry_after() {
    web::live_pressure = pressure(10, 10, 0, 0);
    var c = make_ctx("GET", "");
    var reached = false;
    web::shed_load(c, web::LoadPolicy { retry_after_s: 2 }) { reached = true; };
    assert(!reached);
    assert(c.response.status == web::HTTP_SERVICE_UNAVAILABLE);
    assert(header_value(c.response, "Retry-After") == "2");
    assert(find(web::body_of(c.response), "\"code\":\"overloaded\"") >= 0);
    assert(c.written);
}

fn test_shed_passes_under_load() {
    web::live_pressure = pressure(3, 10, 0, 0);
    var c = make_ctx("GET", "");
    var reached = false;
    web::shed_load(c, web::LoadPolicy { .. }) {
        reached = true;
        c.text("served");
    };
    assert(reached && c.response.status == web::HTTP_OK && web::body_of(c.response) == "served");
    assert(header_value(c.response, "Retry-After").len == 0);
}

fn test_server_pressure_accessor() {
    web::live_pressure = pressure(4, 64, 16384, 8 * 16384);
    var c = make_ctx("GET", "");
    let p = web::server_pressure(c);
    assert(p.active == 4 && p.max_clients == 64 && p.pool_bytes_used == 16384 && p.pool_bytes_max == 8 * 16384);
}

fn test_body_limit() {
    var c = make_ctx("POST", "12345");
    var reached = false;
    web::body_limit(c, 4) { reached = true; };
    assert(!reached);
    assert(c.response.status == web::HTTP_CONTENT_TOO_LARGE);
    assert(find(web::body_of(c.response), "\"code\":\"payload_too_large\"") >= 0);

    var exact = make_ctx("POST", "1234");
    var fits = false;
    web::body_limit(exact, 4) { fits = true; exact.text("ok"); };
    assert(fits && exact.response.status == web::HTTP_OK);

    var none = make_ctx("POST", "");
    var empty_ok = false;
    web::body_limit(none, 0) { empty_ok = true; };
    assert(empty_ok);

    var some = make_ctx("POST", "x");
    var refused = false;
    web::body_limit(some, 0) { refused = true; };
    assert(!refused && some.response.status == web::HTTP_CONTENT_TOO_LARGE);
}

fn main() {
    test_default_policy();
    test_connection_threshold();
    test_pool_threshold();
    test_disabled_checks();
    test_shed_503_with_retry_after();
    test_shed_passes_under_load();
    test_server_pressure_accessor();
    test_body_limit();
    print("Load shedding tests passed: thresholds, disabled checks, 503 with Retry-After, body_limit");
}
