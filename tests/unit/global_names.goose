// Regression: an application's own global names must not collide with the framework. The
// framework once imported the os stdlib, whose global read_file, is_dir and clock_ns then made
// every program's calls ambiguous. This program imports goose_web and not os, and defines
// those names itself.
import goose_web from "../..";
import std;

fn read_file(path: const u8[:]) -> bool { return path.len > 0; }
fn is_dir(path: const u8[:]) -> bool { return path == "dir"; }
fn file_exists(path: const u8[:]) -> bool { return path == "file"; }
fn clock_ns() -> i64 { return -1; }
fn app(c: web::Ctx&) { c.text("unused"); }

fn main() {
    assert(read_file("x") && !read_file(""));
    assert(is_dir("dir") && !is_dir("file") && file_exists("file"));
    assert(clock_ns() == -1);
    // The framework still resolves its own helpers in its own namespace.
    assert(web::clock_ns() > 0);
    var out: u8[>..] = [];
    assert(web::read_bounded_file("tests/fixtures/static/hello.txt", 1024, out) == web::FILE_READ_OK);
    assert(out.len == 25);
    // Instantiating run must not depend on the consumer importing os for write_stderr.
    // An invalid configuration returns before opening any sockets.
    var config = web::server_config();
    config.port = -1;
    let started = web::run(config) { c => app(c) };
    assert(!started);
    print("Global name tests passed: application read_file, is_dir, file_exists and clock_ns coexist with goose_web");
}
