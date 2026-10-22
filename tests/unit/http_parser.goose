import goose_web from "../..";
import std;

fn expect_parser(raw: const u8[:], expected: i32) {
    let request, status = web::parse_request(raw);
    if status != expected { print("Expected ", expected, " got ", status, " for ", raw); }
    assert(status == expected);
    if status != 200 {
        assert(request.method.len == 0 && request.target.len == 0 && request.body.len == 0 && request.raw_headers.len == 0);
    }
}
fn expect_host(host: const u8[:], expected: i32) {
    var raw: u8[..8192] = "GET / HTTP/1.1\r\nHost: ";
    raw.append(host);
    raw.append("\r\n\r\n");
    expect_parser(raw, expected);
}
fn expect_target(target: const u8[:], expected: i32) {
    var raw: u8[..8192] = "GET ";
    raw.append(target);
    raw.append(" HTTP/1.1\r\nHost: localhost\r\n\r\n");
    expect_parser(raw, expected);
}
fn expect_field(field: const u8[:], expected: i32) {
    var raw: u8[..8192] = "POST / HTTP/1.1\r\nHost: localhost\r\n";
    raw.append(field);
    raw.append("\r\n\r\n");
    expect_parser(raw, expected);
}

fn test_host_profile() {
    for host in ["localhost", "example.test", "example.test.", "127.0.0.1:8080", "localhost:0", "localhost:65535",
                 "localhost:0000000000000000080", "xn--bcher-kva.example", "%65xample.test", "a_b", "a!b",
                 "[::]", "[::1]", "[2001:db8::1]:443", "[1:2:3:4:5:6:7:8]", "[::ffff:192.0.2.1]",
                 "[1:2:3:4:5:6:192.0.2.1]", " \tlocalhost\t "] { expect_host(host, 200); }
    for host in ["", " ", "local host", "local\thost", "user@host", "host/path", "host?query", "host#fragment",
                 "host\\path", "host:abc", "host:", ":80", "host:65536", "host:-1", "host:+1", "host:80:90",
                 "host:9999999999999999999999999", "[not-an-ip]", "[::1", "::1", "[]", "[1:2:3:4:5:6:7]",
                 "[1:2:3:4:5:6:7:8:9]", "[1:2:3:4:5:6:7::8]", "[:::]", "[1::2::3]", "[::1]extra",
                 "[12345::1]", "[::ffff:256.0.0.1]", "[::ffff:192.00.2.1]", "[192.0.2.1::]", "[::192.0.2.1:1]",
                 "[fe80::1%25eth0]", "[v1.address]", "host%", "host%GG", "h\xff", "host\x0b"] { expect_host(host, 400); }
    expect_field("Host: duplicate", 400);
}

fn test_target_profile() {
    for target in ["/", "//", "/a//b/", "/a:b@c", "/-._~!$&'()*+,;=", "/%00/%2F/%ff", "/caf%C3%A9",
                   "/?", "/a?x=/b?c&x=%23", "/path?name=%F0%9F%90%A5"] { expect_target(target, 200); }
    for target in ["*", "http://example.test/", "example.test:80", "/#fragment", "/?q=#x", "/%", "/%0", "/%GG",
                   "/?q=%xy", "/?ok=yes&bad=%GG", "/raw\xff", "/caf\xc3\xa9", "/a\\b", "/a[b]", "/a|b", "/a^b",
                   "/a`b", "/a{b}", "/a\"b", "/a<b>", "/a\x00b", "/a\tb", "/a b"] { expect_target(target, 400); }
}

fn test_lines_and_framing() {
    for raw in ["GET / HTTP/1.1\nHost: x\n\n", "GET / HTTP/1.1\rHost: x\r\n\r\n", "GET / HTTP/1.1\r\nHost: x\n\r\n",
                "GET / HTTP/1.1\r\nHost: x\rBroken: y\r\n\r\n", " GET / HTTP/1.1\r\nHost: x\r\n\r\n",
                "GET  / HTTP/1.1\r\nHost: x\r\n\r\n", "GET\t/ HTTP/1.1\r\nHost: x\r\n\r\n",
                "GET / HTTP/1.1 \r\nHost: x\r\n\r\n", "GET / http/1.1\r\nHost: x\r\n\r\n",
                "GET / HTTP/11.1\r\nHost: x\r\n\r\n", "GET / HTTP/1.a\r\nHost: x\r\n\r\n",
                "GET / HTTP/1\r\nHost: x\r\n\r\n", "GET / HTTP/\r\nHost: x\r\n\r\n"] { expect_parser(raw, 400); }
    expect_parser("GET / HTTP/1.0\r\nHost: x\r\n\r\n", 505);
    expect_parser("GET / HTTP/2.0\r\nHost: x\r\n\r\n", 505);
    for field in ["Content-Length: +0", "Content-Length: -0", "Content-Length: 0,0", "Content-Length: 0 0",
                  "Content-Length: 0\t0", "Content-Length:", "Content-Length: \x0b0", "Content-Length: 0\x0c",
                  "Content-Length : 0", "Content-Length: 0\r\ncontent-length: 0", " folded: value", "Bad Name: value",
                  "X: bad\x00value", "X: bad\x7fvalue"] { expect_field(field, 400); }
    expect_field("Content-Length:\t 0000000000000000000000000000000 \t", 200);
    expect_parser("POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 0000000000000000000000000000001\r\n\r\nx", 200);
    expect_field("Content-Length: 9999999999999999999999999999999", 413);
    expect_field("Content-Length: 999999999999999999999999999999x", 400);
    expect_field("Content-Length: 999999999999999999999999\r\nTransfer-Encoding: chunked", 400);
    expect_field("Transfer-Encoding: chunked\r\nContent-Length: 0", 400);
    expect_field("Transfer-Encoding: chunked", 501);
    expect_field("Expect: 100-continue", 417);
    let request, status = web::parse_request("GET / HTTP/1.1\r\nHost:\t x \t\r\nX-Bytes:\t \x80\xff \t\r\n\r\n");
    assert(status == 200 && web::request_header(request, "HOST") == "x");
    assert(web::request_header(request, "x-bytes") == "\x80\xff");
}

fn test_prefixes_and_limits() {
    let raw = "POST /a%2Fb?name=%C3%A9 HTTP/1.1\r\nHost: [::1]:8080\r\nContent-Length: 7\r\n\r\n\x00\xff\r\n\r\nx";
    for n in raw.len { expect_parser(raw[..n], 0); }
    let request, status = web::parse_request(raw);
    assert(status == 200 && request.body == "\x00\xff\r\n\r\nx" && request.target == "/a%2Fb?name=%C3%A9");
    // One request only: trailing pipelined bytes are ignored when <=8192 total.
    expect_parser("GET / HTTP/1.1\r\nHost: x\r\n\r\nGET /next HTTP/1.1\r\n", 200);
    let prefix = "GET / HTTP/1.1\r\nHost: x\r\nX-Pad: ";
    let suffix = "\r\n\r\n";
    let padding: u8[8192] = ['x'; 8192];
    var full_headers: u8[>..] = [];
    full_headers.append(prefix);
    full_headers.append(padding[..8192 - prefix.len - suffix.len]);
    full_headers.append(suffix);
    assert(full_headers.len == 8192);
    expect_parser(full_headers, 200);
    full_headers.push('x');
    expect_parser(full_headers, 413);
    expect_parser(padding[..8191], 0);
    expect_parser(padding, 431);
    let post = "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 8137\r\n\r\n";
    // Derive a fixed four-digit length so header size stays stable.
    let length = 8192 - post.len;
    var body_request: u8[>..] = [];
    format(body_request, "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: ", length, "\r\n\r\n");
    body_request.append(padding[..length]);
    assert(body_request.len == 8192);
    expect_parser(body_request[..8191], 0);
    expect_parser(body_request, 200);
    expect_field("Content-Length: 8192", 413);
}

fn main() {
    test_host_profile();
    test_target_profile();
    test_lines_and_framing();
    test_prefixes_and_limits();
    print("HTTP parser tests passed: strict target, Host, CRLF, OWS, framing, prefixes, binary body, exact limits");
}
