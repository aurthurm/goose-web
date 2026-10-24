// web::config_from_args and web::config_from_env: accepted spellings, ranges, and messages.
import goose_web from "../..";
import std;

// Grow-only bytes behind every argv built here, as os args() keeps its text. All appends
// happen before any slice is taken, so no slice outlives a reallocation.
var argv_text: u8[>..] = [];

// Builds an argv value the way args() does: program name first, empty items skipped.
fn argv_of(a: const u8[:], b: const u8[:], c: const u8[:], d: const u8[:]) -> u8[:][>..] {
    var starts: i64[4] = [0; 4];
    var ends: i64[4] = [0; 4];
    var count: i64 = 0;
    for item in [a, b, c, d] {
        if item.len == 0 { continue; }
        starts[count] = argv_text.len;
        argv_text.append(item);
        ends[count] = argv_text.len;
        count += 1;
    }
    var argv: u8[:][>..] = [];
    for i in count {
        argv.push(argv_text[starts[i]..ends[i]]);
    }
    return argv;
}

fn expect_ok(argv: u8[:][>..], port: i32, clients: i64, requests: i64, public: bool) {
    let config, ok, message = web::config_from_args(argv);
    if !ok { abort(message[..]); }
    assert(config.port == port);
    assert(config.max_clients == clients);
    assert(config.max_requests == requests);
    assert(config.public_bind == public);
}

fn expect_error(argv: u8[:][>..], fragment: const u8[:]) {
    let config, ok, message = web::config_from_args(argv);
    assert(!ok);
    assert(find(message[..], fragment) >= 0);
}

fn test_positional_and_flags() {
    let defaults = web::server_config();
    // Defaults survive when no option is given.
    expect_ok(argv_of("server", "", "", ""), defaults.port, defaults.max_clients, defaults.max_requests, false);
    // A bare first argument is the port (backward compatibility).
    expect_ok(argv_of("server", "9001", "", ""), 9001, defaults.max_clients, defaults.max_requests, false);
    expect_ok(argv_of("server", "--port", "9002", ""), 9002, defaults.max_clients, defaults.max_requests, false);
    expect_ok(argv_of("server", "--port=9003", "", ""), 9003, defaults.max_clients, defaults.max_requests, false);
    expect_ok(argv_of("server", "--host", "public", ""), defaults.port, defaults.max_clients, defaults.max_requests, true);
    expect_ok(argv_of("server", "--host=loopback", "", ""), defaults.port, defaults.max_clients, defaults.max_requests, false);
    expect_ok(argv_of("server", "--max-clients", "4", ""), defaults.port, 4, defaults.max_requests, false);
    expect_ok(argv_of("server", "--max-requests=0", "", ""), defaults.port, defaults.max_clients, 0, false);
    expect_ok(argv_of("server", "9004", "--max-requests", "12"), 9004, defaults.max_clients, 12, false);
}

fn test_rejections() {
    expect_error(argv_of("server", "0", "", ""), "invalid port");
    expect_error(argv_of("server", "65536", "", ""), "invalid port");
    expect_error(argv_of("server", "-1", "", ""), "invalid port");
    expect_error(argv_of("server", "+80", "", ""), "invalid port");
    expect_error(argv_of("server", "80a", "", ""), "invalid port");
    expect_error(argv_of("server", "--port", "", ""), "--port needs a value");
    expect_error(argv_of("server", "--port=99999999999999999999", "", ""), "invalid value for --port");
    expect_error(argv_of("server", "--host", "localhost", ""), "invalid value for --host");
    expect_error(argv_of("server", "--max-clients", "0", ""), "invalid value for --max-clients");
    expect_error(argv_of("server", "--max-clients", "65", ""), "invalid value for --max-clients");
    expect_error(argv_of("server", "--max-requests", "-1", ""), "invalid value for --max-requests");
    expect_error(argv_of("server", "--unknown", "1", ""), "unknown option: --unknown");
    expect_error(argv_of("server", "9000", "extra", ""), "unexpected argument: extra");
}

fn test_workers() {
    // --workers is 0 (one per CPU) or 1..MAX_WORKERS; the default keeps the single-process reactor.
    assert(web::server_config().workers == 1);
    let config, ok, message = web::config_from_args(argv_of("server", "--workers", "4", ""));
    if !ok { abort(message[..]); }
    assert(config.workers == 4);
    let zero, zero_ok, zero_message = web::config_from_args(argv_of("server", "--workers=0", "", ""));
    if !zero_ok { abort(zero_message[..]); }
    assert(zero.workers == 0);
    let maximum, max_ok, max_message = web::config_from_args(argv_of("server", "--workers", "256", ""));
    if !max_ok { abort(max_message[..]); }
    assert(maximum.workers == web::MAX_WORKERS);
    expect_error(argv_of("server", "--workers", "257", ""), "invalid value for --workers");
    expect_error(argv_of("server", "--workers", "-1", ""), "invalid value for --workers");
    expect_error(argv_of("server", "--workers", "two", ""), "invalid value for --workers");
    var bad = web::server_config();
    bad.workers = -1;
    assert(!web::validate_server_config(bad));
    bad.workers = web::MAX_WORKERS + 1;
    assert(!web::validate_server_config(bad));
    bad.workers = web::MAX_WORKERS;
    assert(web::validate_server_config(bad));
}

fn test_environment_defaults() {
    // The test runner does not set GOOSE_WEB_*, so the defaults must come back as ok.
    let config, ok, message = web::config_from_env();
    if !ok { abort(message[..]); }
    assert(config.port == web::DEFAULT_PORT && !config.public_bind);
}

fn main() {
    test_positional_and_flags();
    test_rejections();
    test_workers();
    test_environment_defaults();
    print("App config tests passed: positional port, flags, workers, ranges, messages, environment defaults");
}
