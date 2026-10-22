// Reproducible splitmix64 corpus: seeds and iteration counts are deliberate.
// Run a debug build so index/slice assertions remain active.
// 33,119 checked inputs: 8,192 seeded mutations/random frames plus structured cases.
import goose_web from "../..";
import std;

var calls: i64 = 0;

fn same_root(view: const u8[:], raw: const u8[:], offset: i64) {
    assert(offset >= 0 && offset + view.len <= raw.len);
    assert(view == raw[offset..offset + view.len]);
    if view.len > 0 {
        let actual .= view[0];
        let expected .= raw[offset];
        assert(actual .== expected);
    }
}

fn check(raw: const u8[:]) -> i32 {
    calls += 1;
    let request, status = web::parse_request(raw);
    assert(status == 0 || status == 200 || status == 400 || status == 413 ||
           status == 417 || status == 431 || status == 501 || status == 505);
    if status != 200 {
        assert(request.method.len == 0 && request.target.len == 0 &&
               request.body.len == 0 && request.raw_headers.len == 0);
        return status;
    }
    assert(raw.len <= 8192 && request.method.len > 0 && request.target.len > 0);
    let first = find(raw, " ");
    let line_end = find(raw, "\r\n");
    let headers_end = find(raw, "\r\n\r\n");
    assert(first > 0 && line_end > first && headers_end >= line_end);
    same_root(request.method, raw, 0);
    same_root(request.target, raw, first + 1);
    same_root(request.raw_headers, raw, line_end + 2);
    assert(request.raw_headers.len == headers_end - line_end);
    same_root(request.body, raw, headers_end + 4);
    assert(web::request_header(request, "Host").len > 0);
    let length_text = web::request_header(request, "Content-Length");
    if length_text.len > 0 {
        let length, valid = parse_int(length_text);
        assert(valid && length == request.body.len);
    } else { assert(request.body.len == 0); }
    return status;
}

fn arbitrary(seed: u64) {
    var random = rng { s: seed };
    let base = "POST /safe?x=1 HTTP/1.1\r\nHost: localhost\r\nContent-Length: 4\r\n\r\nbody";
    for iteration in 2048 {
        var raw: u8[>..] = [];
        if iteration % 4 == 0 {
            // Mutate near-valid syntax so parsing reaches deep header/body paths.
            raw.append(base);
            for edit in 1 + rand_int(random, 8) {
                raw[rand_int(random, raw.len)] = rand_int(random, 256) as u8;
            }
            if iteration % 8 == 0 { raw.resize(rand_int(random, raw.len + 1)); }
        } else {
            let length = if iteration % 32 == 1 { 8192 } else { rand_int(random, 1025) };
            for i in length { raw.push(rand_int(random, 256) as u8); }
            // Supply a framing terminator to avoid only exercising incomplete input.
            if raw.len >= 4 && iteration % 3 == 0 {
                let offset = rand_int(random, raw.len - 3);
                raw[offset] = 13; raw[offset + 1] = 10;
                raw[offset + 2] = 13; raw[offset + 3] = 10;
            }
        }
        check(raw);
    }
}

fn structured() {
    var random = rng { s: 20261022 };
    for iteration in 256 {
        var body: u8[>..] = [];
        let length = iteration % 65;
        for i in length { body.push(rand_int(random, 256) as u8); }
        var raw: u8[>..] = [];
        format(raw, "POST /safe?x=1 HTTP/1.1\r\nHost: localhost\r\nContent-Length: ", length, "\r\n\r\n");
        raw.append(body);
        assert(check(raw) == 200);
        let request, status = web::parse_request(raw);
        assert(status == 200 && request.method == "POST" && request.target == "/safe?x=1" && request.body == body);
        // Every strict prefix of a valid frame remains incomplete.
        for prefix in raw.len { assert(check(raw[..prefix]) == 0); }
        raw.append("GET /second HTTP/1.1\r\nHost: localhost\r\n\r\n");
        assert(check(raw) == 200);
        let first, parsed = web::parse_request(raw);
        assert(parsed == 200 && first.body == body && first.target == "/safe?x=1");
    }
    // Exact full-buffer boundary with a binary body and no trailing bytes.
    var boundary: u8[>..] = [];
    let header = "POST /safe?x=1 HTTP/1.1\r\nHost: localhost\r\nContent-Length: 8125\r\n\r\n";
    let body_length = 8192 - header.len;
    // Header length is fixed because the calculated body length has four digits.
    format(boundary, "POST /safe?x=1 HTTP/1.1\r\nHost: localhost\r\nContent-Length: ", body_length, "\r\n\r\n");
    for i in body_length { boundary.push((i % 256) as u8); }
    assert(boundary.len == 8192 && check(boundary) == 200);
}

fn main() {
    arbitrary(1); arbitrary(42); arbitrary(20261022); arbitrary(3735928559);
    structured();
    print("Parser fuzz/property tests passed: ", calls, " checked inputs; splitmix64 seeds 1,42,20261022,3735928559");
}
