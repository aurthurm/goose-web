// Static file reads: stat-first size checks, the response cap, and the middleware's error
// codes. Files are written under the directory given on the command line (the runner passes
// a temporary one). The file-reading shim is src/sys/files.goose, not the os stdlib.
import goose_web from "../..";
import std;
import os;

fn next_called() { abort("static middleware must not call Next for a served file"); }

fn path_in(out: u8[>..]&, directory: const u8[:], name: const u8[:]) {
    out.clear();
    format(out, directory, "/", name);
}

fn expect_read(directory: const u8[:], name: const u8[:], expected: i32, body_len: i64) -> u8[>..] {
    var path: u8[>..] = [];
    path_in(path, directory, name);
    var out: u8[>..] = [];
    let status = web::read_bounded_file(path[..], web::MAX_RESPONSE_BODY_BYTES, out);
    assert(status == expected);
    assert(out.len == body_len);
    return out;
}

fn test_read_bounded(directory: const u8[:]) {
    var path: u8[>..] = [];
    // Missing and directory entries are reported as missing; nothing is read.
    expect_read(directory, "absent.txt", web::FILE_READ_MISSING, 0);
    expect_read(directory, "", web::FILE_READ_MISSING, 0);

    // A small file comes back whole.
    path_in(path, directory, "small.txt");
    assert(write_file(path[..], "hello static"));
    let small = expect_read(directory, "small.txt", web::FILE_READ_OK, 12);
    assert(small == "hello static");

    // Exactly the cap is served; one byte over is refused before any byte is read.
    var cap: u8[>..] = [];
    cap.resize(web::MAX_RESPONSE_BODY_BYTES, 'x');
    path_in(path, directory, "cap.bin");
    assert(write_file(path[..], cap[..]));
    expect_read(directory, "cap.bin", web::FILE_READ_OK, web::MAX_RESPONSE_BODY_BYTES);

    var over: u8[>..] = [];
    over.resize(web::MAX_RESPONSE_BODY_BYTES + 1, 'y');
    path_in(path, directory, "over.bin");
    assert(write_file(path[..], over[..]));
    expect_read(directory, "over.bin", web::FILE_READ_TOO_LARGE, 0);
}

fn test_middleware_errors(directory: const u8[:]) {
    // Oversize files answer 500 file_too_large through the middleware, without Next.
    var c = web::new_ctx(web::Request { method: "GET", target: "/static/over.bin", body: "", raw_headers: "Host: x\r\n" });
    web::static_files(c, "/static", directory) { next_called(); };
    assert(c.written && c.response.status == web::HTTP_INTERNAL_SERVER_ERROR);
    assert(find(c.response.body[..], "\"code\":\"file_too_large\"") >= 0);

    // A missing file answers 404 not_found.
    var missing = web::new_ctx(web::Request { method: "GET", target: "/static/absent.txt", body: "", raw_headers: "Host: x\r\n" });
    web::static_files(missing, "/static", directory) { next_called(); };
    assert(missing.response.status == web::HTTP_NOT_FOUND);
}

fn main() {
    assert(args().len == 2);
    let directory = args()[1];
    test_read_bounded(directory);
    test_middleware_errors(directory);
    print("Static file tests passed: stat-first size limit at the response cap, bounded reads, middleware error codes");
}
