import goose_web from "../..";
import std;

fn test_events() {
    var bus = web::event_bus<i64>();
    let first = web::subscribe(bus, 1);
    let once = web::subscribe(bus, 1, true);
    let other = web::subscribe(bus, 2);
    var seen: i64[>..] = [];
    assert(web::dispatch(bus, 1, 42));
    assert(web::dispatch(bus, 1, 43));
    assert(web::drain(bus) { id, event =>
        seen.push(id);
        assert(event.args >= 42 && event.args <= 43);
    } == 2);
    assert(seen.len == 3 && seen[0] == first && seen[1] == once && seen[2] == first);
    assert(!web::unsubscribe(bus, once));
    assert(web::unsubscribe(bus, first));
    assert(web::unsubscribe(bus, other));

    // Reused slots still deliver in subscription order, not slot order.
    let a = web::subscribe(bus, 3);
    let b = web::subscribe(bus, 3);
    assert(web::unsubscribe(bus, a));
    let c = web::subscribe(bus, 3);
    assert(web::dispatch(bus, 3, 1));
    var order: i64[>..] = [];
    web::drain(bus) { id, event => order.push(id); };
    assert(order.len == 2 && order[0] == b && order[1] == c);

    // Listener mutation and nested dispatch must neither recurse nor grow a turn.
    var nested = web::event_bus<i64>();
    let n1 = web::subscribe(nested, 1);
    let n2 = web::subscribe(nested, 1);
    var late: i64 = 0;
    var calls: i64 = 0;
    assert(web::dispatch(nested, 1, 10));
    web::drain(nested) { id, event =>
        calls += 1;
        assert(id == n1);
        assert(web::unsubscribe(nested, n2));
        late = web::subscribe(nested, 1);
        assert(web::dispatch(nested, 1, 20));
        assert(web::drain(nested) { x, e => abort("recursive drain"); } == 0);
    };
    assert(calls == 1 && nested.count == 1);
    web::drain(nested) { id, event =>
        assert(event.args == 20);
        assert(id == n1 || id == late);
        calls += 1;
    };
    assert(calls == 3 && nested.count == 0);

    var full = web::event_bus<i64>();
    for i in 64 { assert(web::subscribe(full, 1) > 0); }
    assert(web::subscribe(full, 1) == 0);
    for round in 3 {
        for i in 256 { assert(web::dispatch(full, 7, i)); }
        assert(!web::dispatch(full, 7, -1));
        assert(web::drain(full) { id, event => abort("wrong topic"); } == 256);
        assert(full.count == 0);
    }
}

fn expect_status(raw: u8[:], expected: i32) {
    let request, status = web::parse_request(raw);
    assert(status == expected);
}

fn test_http() {
    expect_status("GET / HTTP/1.1\r\nHost: localhost\r\n\r\n", 200);
    expect_status("GET / HTTP/1.1\r\nHost:", 0);
    expect_status("POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 4\r\n\r\nab", 0);
    let request, status = web::parse_request("POST /echo?x=1 HTTP/1.1\r\nHost: x\r\nContent-Length: 4\r\n\r\nabcd");
    assert(status == 200 && request.method == "POST" && request.target == "/echo?x=1" && request.body == "abcd");
    expect_status("GET / HTTP/1.1\r\n\r\n", 400);
    expect_status("GET / HTTP/1.1\r\nHost: x\r\nHost: y\r\n\r\n", 400);
    expect_status("GET / HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\ncontent-length: 0\r\n\r\n", 400);
    expect_status("GET / HTTP/1.1\r\nHost: x\r\nContent-Length: -1\r\n\r\n", 400);
    expect_status("GET / HTTP/1.1\r\nHost: x\r\nContent-Length: 999999999999999999999999\r\n\r\n", 413);
    expect_status("GET / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\nContent-Length: 1\r\n\r\nx", 400);
    expect_status("GET / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n", 501);
    expect_status("POST / HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\n\r\n", 417);
    expect_status("GET / HTTP/1.0\r\nHost: x\r\n\r\n", 505);
    expect_status("GET / HTTP/1.1\r\nHost : x\r\n\r\n", 400);
    expect_status("GET / HTTP/1.1\r\nHost: x\r\n folded: value\r\n\r\n", 400);
    expect_status("GET / HTTP/1.1\r\nHost: x\r\nX: bad\x00value\r\n\r\n", 400);
    var big: u8[8192] = ['x'; 8192];
    expect_status(big, 431);

    var r = web::response();
    r.body = "hello";
    var wire: u8[>..] = [];
    web::serialize_response(wire, r);
    assert(find(wire, "Content-Length: 5\r\n") >= 0);
    assert(find(wire, "\r\n\r\nhello") >= 0);
    var head: u8[>..] = [];
    web::serialize_response(head, r, true);
    assert(find(head, "Content-Length: 5\r\n") >= 0 && find(head, "hello") < 0);
    r.status = 204;
    var no_content: u8[>..] = [];
    web::serialize_response(no_content, r);
    assert(find(no_content, "Content-Length") < 0 && find(no_content, "hello") < 0);
    r.content_type = "text/plain\r\nInjected: yes";
    var invalid: u8[>..] = [];
    web::serialize_response(invalid, r);
    assert(r.status == 500 && find(invalid, "Injected") < 0);
}

fn test_headers() {
    let req, status = web::parse_request("GET / HTTP/1.1\r\nHost: local\r\nX-Trace:  abc \t\r\n\r\n");
    assert(status == 200 && web::request_header(req, "x-TRACE") == "abc");
    assert(web::request_header(req, "missing") == "");
    var r = web::response();
    assert(web::set_header(r, "X-Trace", "first"));
    assert(web::set_header(r, "x-trace", "second"));
    assert(r.headers.len == 1 && r.headers[0].value == "second");
    assert(!web::set_header(r, "Content-Length", "1"));
    assert(!web::set_header(r, "Transfer-Encoding", "chunked"));
    assert(!web::set_header(r, "Connection", "keep-alive"));
    assert(!web::set_header(r, "X-Trace", "bad\r\nInjected: yes"));
    assert(!web::set_header(r, "Bad Name", "x"));
    assert(r.headers.len == 1 && r.headers[0].value == "second");
    var serialized: u8[>..] = [];
    web::serialize_response(serialized, r);
    assert(find(serialized, "X-Trace: second\r\n") >= 0);
    // Public structs remain checked even when callers bypass set_header.
    r.headers.push(web::Header { name: "Content-Length", value: "0" });
    var invalid: u8[>..] = [];
    web::serialize_response(invalid, r);
    assert(r.status == 500 && r.headers.len == 0);
    var full = web::response();
    for i in 16 {
        let name = str("X-", i);
        assert(web::set_header(full, name, "v"));
    }
    assert(!web::set_header(full, "X-Extra", "v"));
    assert(web::set_header(full, "x-0", "replace"));
    let big: u8[257] = ['x'; 257];
    assert(!web::set_header(full, "X-0", big));
    assert(full.headers[0].value == "replace");
}

fn main() {
    test_events();
    test_http();
    test_headers();
    print("Core tests passed: events, HTTP parsing, response framing");
}
