import src.constants.http;
import src.constants.limits;
import src.runtime.server;
import src.app.context;
import src.app.middleware;
import std;
namespace web;

// Load shedding and per-route body caps. See docs/api.md#load-shedding.
// The reactor publishes live_pressure before each handler runs (record_pressure in server.goose), so the
// numbers describe the moment the request was read. Each worker process has its own reactor and its own numbers.

// A percentage of 0 turns that check off; 1 to 100 sets the level at which requests are shed.
// retry_after_s is the Retry-After value (whole seconds, at least 1).
struct LoadPolicy { max_active_connections_pct: i32 = 90, max_pool_used_pct: i32 = 90, retry_after_s: i64 = 1 }

// Whether the pressure reaches one of the policy's levels. The comparisons use multiplication, so no
// division rounding moves a threshold. A limit of zero (no max_clients or pool) is never reached.
fn load_pressure_high(p: ServerPressure, policy: LoadPolicy) -> bool {
    if policy.max_active_connections_pct > 0 && p.max_clients > 0 &&
       p.active * 100 >= p.max_clients * (policy.max_active_connections_pct) { return true; }
    if policy.max_pool_used_pct > 0 && p.pool_bytes_max > 0 &&
       p.pool_bytes_used * 100 >= p.pool_bytes_max * (policy.max_pool_used_pct) { return true; }
    return false;
}

// The reactor's latest snapshot. Zero until the first request is read (all limits are then off).
fn server_pressure(c: Ctx&) -> ServerPressure {
    return live_pressure;
}

// Refuses the request with 503 and error code "overloaded", plus Retry-After, when the reactor reports pressure
// at or above the policy. Otherwise calls Next. Put it on the routes that can be
// shed; health checks usually stay outside it.
fn shed_load<Next>(c: Ctx&, policy: LoadPolicy) {
    assert(policy.max_active_connections_pct >= 0 && policy.max_active_connections_pct <= 100);
    assert(policy.max_pool_used_pct >= 0 && policy.max_pool_used_pct <= 100);
    assert(policy.retry_after_s >= 1);
    if load_pressure_high(server_pressure(c), policy) {
        var seconds: u8[>..] = [];
        format(seconds, policy.retry_after_s);
        c.set(HEADER_RETRY_AFTER, seconds[..]);
        c.fail(HTTP_SERVICE_UNAVAILABLE, "overloaded", "Server is overloaded; retry later");
        return;
    }
    Next();
}

// Refuses a request whose body is longer than bytes with 413 payload_too_large, before the handler runs. A
// route that takes small payloads can use a lower cap than ServerConfig.max_request_bytes, which still bounds
// every request.
fn body_limit<Next>(c: Ctx&, bytes: i64) {
    assert(bytes >= 0);
    if c.request.body.len > bytes {
        c.fail(HTTP_CONTENT_TOO_LARGE, "payload_too_large", "Request body is too large");
        return;
    }
    Next();
}
