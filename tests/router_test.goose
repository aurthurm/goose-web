// Smoke tests for the Goose-only route matching core.
import std;
import web from "..";

fn main() {
    assert(route_matches("/", "/"));
    assert(route_matches("/health", "/health"));
    assert(route_matches("/users/:id", "/users/42"));
    assert(route_matches("/v1/items/:item", "/v1/items/abc"));
    assert(!route_matches("/health", "/health/"));
    assert(!route_matches("/users/:id", "/users/"));
    assert(!route_matches("/users/:id", "/users/42/orders"));
    assert(!route_matches("/users/:", "/users/42"));
    assert(!route_matches("/items", "/users"));
    assert(status_reason(404) == "Not Found");
    print("router tests passed");
}
