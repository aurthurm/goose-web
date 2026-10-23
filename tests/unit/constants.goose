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
    assert(config.max_pool_bytes == 8388608 && web::DEFAULT_MAX_POOL_BYTES == config.max_pool_bytes);
    assert(web::MAX_RESPONSE_BODY_BYTES == 16777216 && web::MAX_ERROR_BODY_BYTES == 65536);
    assert(web::MAX_RESPONSE_POOL_BYTES == 67108864 && web::MAX_POOL_CHUNKS * web::RESPONSE_CHUNK_BYTES == web::MAX_RESPONSE_POOL_BYTES);
    assert(web::MAX_RESPONSE_POOL_BYTES >= web::MAX_RESPONSE_WIRE_BYTES);
    assert(web::MAX_REQUEST == web::MAX_REQUEST_BYTES); // Original name remains available.
    // Keep the capacity shared across the Goose/C boundary in agreement.
    assert(web::gw_transport_max_clients() == web::MAX_CLIENTS);
    assert(web::MAX_POLL_FDS == web::MAX_CLIENTS + 1 && web::LISTENER_TOKEN == web::MAX_CLIENTS);
    // The input classes double from INPUT_MIN_BYTES up to the largest request.
    assert(web::INPUT_MIN_BYTES * (1 << (web::INPUT_CLASSES - 1)) >= web::MAX_REQUEST_BYTES);
    var bus = web::event_bus<i64>();
    assert(!web::unsubscribe(bus, web::INVALID_SUBSCRIPTION));
    assert(bus.listeners.len == web::MAX_EVENT_LISTENERS && bus.queue.len == web::MAX_QUEUED_EVENTS);
}

fn test_response_capacity() {
    // All declared response limits at once must still fit the wire size bound.
    var r = web::response();
    r.max_body = web::MAX_RESPONSE_BODY_BYTES;
    var body: u8[>..] = [];
    body.resize(web::MAX_RESPONSE_BODY_BYTES, 'b');
    let content_type: u8[web::MAX_CONTENT_TYPE_BYTES] = ['t'; web::MAX_CONTENT_TYPE_BYTES];
    let value: u8[web::MAX_HEADER_VALUE_BYTES] = ['v'; web::MAX_HEADER_VALUE_BYTES];
    assert(web::set_body(r, body[..]));
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
    assert(find(wire, "Content-Length: 16777216\r\n") >= 0);
}

// The pool holds one chunk here: a response that fits is staged, and a second one is refused
// (the reactor answers that with 503) until the first is released.
fn test_pool_budget() {
    var pool = web::ChunkPool { count: 0, free_count: 0, max_chunks: 1, free: [0; web::MAX_POOL_CHUNKS],
        next: [0; web::MAX_POOL_CHUNKS], bytes: [] };
    var head: u8[>..] = [];
    var first = default<web::Connection>();
    var r = web::response();
    assert(web::set_body(r, "small"));
    assert(web::stage_response(first, pool, head, r, false, true, false, 1000));
    assert(first.wire_len > 0 && first.writing && first.head != web::NO_CHUNK);
    var second = default<web::Connection>();
    var s = web::response();
    assert(web::set_body(s, "again"));
    assert(!web::stage_response(second, pool, head, s, false, true, false, 1000));
    assert(second.wire_len == 0 && !second.writing);
    // A response of two chunks never fits a one-chunk pool.
    var big = web::response();
    var payload: u8[>..] = [];
    payload.resize(web::RESPONSE_CHUNK_BYTES * 2, 'p');
    big.max_body = web::MAX_RESPONSE_BODY_BYTES;
    assert(web::set_body(big, payload[..]));
    assert(!web::stage_response(second, pool, head, big, false, true, false, 1000));
    web::release_chunks(first, pool);
    assert(web::stage_response(second, pool, head, s, false, true, false, 1000));
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
    test_pool_budget();
    test_status_phrases();
    print("Constants tests passed: public imports, wire values, defaults, native capacity, maximum response framing");
}
