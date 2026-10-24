// Structured request logs: the RFC 3339 timestamp, the JSON line shape, escaping and truncation, and the
// json_logger middleware on a Ctx.
import goose_web from "../..";
import std;

fn line_of(e: web::LogEntry) -> u8[>..] {
    var out: u8[>..] = [];
    web::json_log_line(out, e);
    return out;
}

fn entry() -> web::LogEntry {
    return web::LogEntry { unix_seconds: 0, request_id: 7, method: "GET", path: "/users/42", route: "/users/:id",
        status: 200, bytes: 9, duration_us: 12, peer: "127.0.0.1", client_ip: "203.0.113.9", user_agent: "curl/8.0",
        pid: 0 };
}

fn test_timestamp() {
    var out: u8[>..] = [];
    web::log_timestamp(out, 0);
    assert(out[..] == "1970-01-01T00:00:00Z");
    var leap: u8[>..] = [];
    web::log_timestamp(leap, 951782400);
    assert(leap[..] == "2000-02-29T00:00:00Z");
    var known: u8[>..] = [];
    web::log_timestamp(known, 1700000000);
    assert(known[..] == "2023-11-14T22:13:20Z");
    var next_century: u8[>..] = [];
    web::log_timestamp(next_century, 4102444800);
    assert(next_century[..] == "2100-01-01T00:00:00Z");
    var negative: u8[>..] = [];
    web::log_timestamp(negative, -5);
    assert(negative[..] == "1970-01-01T00:00:00Z");
}

fn test_line_shape() {
    let line = line_of(entry());
    assert(line[..] == "{\"ts\":\"1970-01-01T00:00:00Z\",\"level\":\"info\",\"request_id\":7,\"method\":\"GET\",\"path\":\"/users/42\",\"route\":\"/users/:id\",\"status\":200,\"bytes\":9,\"duration_us\":12,\"peer\":\"127.0.0.1\",\"client_ip\":\"203.0.113.9\",\"user_agent\":\"curl/8.0\"}");
}

fn test_levels_and_missing_route() {
    var e = entry();
    e.status = 404;
    e.route = "";
    let warn = line_of(e);
    assert(find(warn[..], "\"level\":\"warn\"") >= 0 && find(warn[..], "\"route\":null") >= 0);
    e.status = 503;
    let error = line_of(e);
    assert(find(error[..], "\"level\":\"error\"") >= 0);
}

fn test_worker_pid() {
    var e = entry();
    e.pid = 4242;
    let line = line_of(e);
    assert(line[line.len - 1] == '}' && find(line[..], ",\"pid\":4242}") >= 0);
}

fn test_escaping() {
    var e = entry();
    e.path = "/a\"b\\c";
    e.user_agent = "x\x01y\"z";
    let line = line_of(e);
    assert(find(line[..], "\"path\":\"/a\\\"b\\\\c\"") >= 0);
    assert(find(line[..], "\"user_agent\":\"x?y\\\"z\"") >= 0);
    // Non-ASCII bytes are masked, so a crafted header cannot inject multibyte text or break the line.
    e.user_agent = "caf\xc3\xa9\n";
    let masked = line_of(e);
    assert(find(masked[..], "\"user_agent\":\"caf???\"") >= 0);
    assert(find(masked[..], "\n") < 0);
    // A target with an embedded CRLF stays on one line.
    e.path = "/x\r\nHTTP/1.1";
    let split = line_of(e);
    assert(find(split[..], "\r") < 0 && find(split[..], "\n") < 0);
}

fn test_user_agent_truncated() {
    var e = entry();
    var long: u8[>..] = [];
    for i in 300 { long.push('a'); }
    e.user_agent = long[..];
    let line = line_of(e);
    var expect: u8[>..] = [];
    for i in 128 { expect.push('a'); }
    assert(find(line[..], expect[..]) >= 0);
    var too_long: u8[>..] = [];
    for i in 129 { too_long.push('a'); }
    assert(find(line[..], too_long[..]) < 0);
}

// The middleware runs Next, then prints. Its output is not captured here; the socket test checks it.
fn test_middleware_calls_next() {
    var out = web::response();
    var scratch = web::AppScratch { .. };
    var c = web::new_ctx(web::Request { method: "GET", target: "/a?b=1", body: "", raw_headers: "Host: x\r\n", peer: "127.0.0.1" }, out, scratch);
    var reached = false;
    web::json_logger(c, false) {
        reached = true;
        c.text("ok");
    };
    assert(reached && web::body_of(c.response) == "ok");
}

fn main() {
    test_timestamp();
    test_line_shape();
    test_levels_and_missing_route();
    test_worker_pid();
    test_escaping();
    test_user_agent_truncated();
    test_middleware_calls_next();
    print("Structured log tests passed: timestamp, line shape, levels, escaping, truncation, middleware");
}
