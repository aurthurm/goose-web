// Import only the public package, just as an application does.
import goose_web from "../..";
import std;

fn test_public_api() {
    var routes = web::router();
    assert(web::add_route(routes, web::METHOD_GET, "/example", 1));
    let found = web::match_route(routes, web::METHOD_HEAD, "/example");
    assert(found.status == web::HTTP_OK);
    let missing = web::query_value("/example", "absent");
    assert(missing.status == web::QUERY_MISSING);
    let request, status = web::parse_request("GET /");
    assert(status == web::PARSE_INCOMPLETE);
    var r = web::response();
    assert(r.status == web::HTTP_OK && r.content_type == web::CONTENT_TYPE_TEXT);
    assert(web::set_header(r, web::HEADER_REQUEST_ID, "public-constants"));
    assert(web::application_error(r, web::HTTP_NOT_FOUND, "not_found", "Missing"));
    assert(r.content_type == web::CONTENT_TYPE_JSON);
    var wire: u8[>..] = [];
    web::serialize_response(wire, r);
    assert(find(wire, "HTTP/1.1 404 Not Found\r\n") == 0);
    assert(find(wire, "X-Request-ID: public-constants\r\n") >= 0);

    let config = web::server_config();
    assert(config.port == web::DEFAULT_PORT && config.max_clients == web::DEFAULT_MAX_CLIENTS);
    assert(config.max_request_bytes == web::DEFAULT_MAX_REQUEST_BYTES);
    assert(config.read_timeout_ms == web::DEFAULT_READ_TIMEOUT_MS);
    assert(config.write_timeout_ms == web::DEFAULT_WRITE_TIMEOUT_MS);
    assert(config.poll_timeout_ms == web::DEFAULT_POLL_TIMEOUT_MS);
    assert(config.shutdown_grace_ms == web::DEFAULT_SHUTDOWN_GRACE_MS);
    assert(config.max_requests == web::UNLIMITED_REQUESTS && web::validate_server_config(config));
    // Persistence and response-size defaults are public contract (docs/api.md).
    assert(config.keep_alive && config.idle_timeout_ms == 5000);
    assert(config.max_requests_per_connection == 100 && config.max_response_bytes == 1048576);
    assert(web::MAX_RESPONSE_BODY_BYTES == 1048576 && web::MAX_RESPONSE_CHUNKS * web::RESPONSE_CHUNK_BYTES >= web::MAX_RESPONSE_WIRE_BYTES);
    assert(web::MAX_REQUEST == web::MAX_REQUEST_BYTES); // Original name remains available.
    // Keep the capacity shared across the Goose/C boundary in agreement.
    assert(web::gw_transport_max_clients() == web::MAX_CLIENTS);
    assert(web::MAX_POLL_FDS == web::MAX_CLIENTS + 1);
    var bus = web::event_bus<i64>();
    assert(!web::unsubscribe(bus, web::INVALID_SUBSCRIPTION));
    assert(bus.listeners.len == web::MAX_EVENT_LISTENERS && bus.queue.len == web::MAX_QUEUED_EVENTS);
}

fn test_response_capacity() {
    // All declared response limits at once must still fit the reactor's wire buffer.
    var r = web::response();
    let body: u8[web::MAX_RESPONSE_BODY_BYTES] = ['b'; web::MAX_RESPONSE_BODY_BYTES];
    let content_type: u8[web::MAX_CONTENT_TYPE_BYTES] = ['t'; web::MAX_CONTENT_TYPE_BYTES];
    let value: u8[web::MAX_HEADER_VALUE_BYTES] = ['v'; web::MAX_HEADER_VALUE_BYTES];
    r.body = body;
    r.content_type = content_type;
    for i in web::MAX_RESPONSE_HEADERS {
        var name: u8[..web::MAX_HEADER_NAME_BYTES] = [];
        format(name, "X-", i, "-");
        while name.len < web::MAX_HEADER_NAME_BYTES { name.push('n'); }
        assert(web::set_header(r, name, value));
    }
    var wire: u8[>..] = [];
    web::serialize_response(wire, r);
    assert(r.status == web::HTTP_OK && wire.len <= web::MAX_RESPONSE_WIRE_BYTES);
    assert(find(wire, "Content-Length: 1048576\r\n") >= 0);
}

fn test_status_phrases() {
    // Independent wire expectations keep refactoring constants from hiding drift.
    assert(web::HTTP_ACCEPTED == 202 && web::reason(web::HTTP_ACCEPTED) == "Accepted");
    assert(web::HTTP_PARTIAL_CONTENT == 206 && web::reason(web::HTTP_PARTIAL_CONTENT) == "Partial Content");
    assert(web::HTTP_NOT_MODIFIED == 304 && web::reason(web::HTTP_NOT_MODIFIED) == "Not Modified");
    assert(web::HTTP_PERMANENT_REDIRECT == 308 && web::reason(web::HTTP_PERMANENT_REDIRECT) == "Permanent Redirect");
    assert(web::HTTP_UNPROCESSABLE_CONTENT == 422 && web::reason(web::HTTP_UNPROCESSABLE_CONTENT) == "Unprocessable Content");
    assert(web::HTTP_TOO_MANY_REQUESTS == 429 && web::reason(web::HTTP_TOO_MANY_REQUESTS) == "Too Many Requests");
    assert(web::HTTP_BAD_GATEWAY == 502 && web::reason(web::HTTP_BAD_GATEWAY) == "Bad Gateway");
    assert(web::HTTP_GATEWAY_TIMEOUT == 504 && web::reason(web::HTTP_GATEWAY_TIMEOUT) == "Gateway Timeout");
    assert(web::reason(299) == "Response");
}

fn main() {
    test_public_api();
    test_response_capacity();
    test_status_phrases();
    print("Constants tests passed: public imports, wire values, defaults, native capacity, maximum response framing");
}
