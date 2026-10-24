import std;
namespace web;

// Regular-file access for static files, without importing the os stdlib. Every framework
// module that imports os leaks its global names (read_file, is_dir, ...) into each program,
// so the framework keeps its own narrow shim over native/posix/system.c instead. Stat follows
// symbolic links, matching the static-file rules in docs/api.md; file_within resolves links
// for the containment check.

// Mirror native/posix/constants.h (GW_FILE_*).
const FILE_KIND_MISSING = 0;
const FILE_KIND_REGULAR = 1;
const FILE_KIND_DIRECTORY = 2;
const FILE_KIND_OTHER = 3;
const FILE_KIND_ERROR = -1;

// Outcomes of read_bounded_file.
const FILE_READ_OK = 0;
const FILE_READ_MISSING = 1;
const FILE_READ_FAILED = 2;
const FILE_READ_TOO_LARGE = 3;

// Kind of the entry at `path`; `size` is set only for a regular file.
extern fn gw_file_stat(path: const u8[:], size: i64&) -> i32;
// Copies at most buffer.len bytes of a regular file into buffer. Returns the count, or -1.
extern fn gw_file_read(path: const u8[:], buffer: u8[:]) -> i64;

// 1 when the real location of path (symbolic links resolved) is root or below it, 0 when outside,
// -1 when either cannot be resolved. Static files use it so links cannot leave the served tree.
extern fn gw_file_within(root: const u8[:], path: const u8[:]) -> i32;

fn file_within(root: const u8[:], path: const u8[:]) -> bool {
    return gw_file_within(root, path) == 1;
}

fn file_kind(path: const u8[:]) -> i32 {
    var size: i64 = 0;
    return gw_file_stat(path, size);
}

// Appends a regular file of exactly its stat size to `out`, but only when that size is at most
// max_bytes. A file over the limit is refused before any read. The read asks for size + 1 bytes
// so that a file which changed size during the read is detected instead of truncated or padded:
// the count must equal the stat size. Never reads more than max_bytes + 1 bytes.
fn read_bounded_file(path: const u8[:], max_bytes: i64, out: u8[>..]&) -> i32 {
    var size: i64 = 0;
    let kind = gw_file_stat(path, size);
    if kind == FILE_KIND_ERROR { return FILE_READ_FAILED; }
    if kind != FILE_KIND_REGULAR { return FILE_READ_MISSING; }
    if size > max_bytes { return FILE_READ_TOO_LARGE; }
    let start = out.len;
    out.resize(start + size + 1, 0);
    let count = gw_file_read(path, out[start..]);
    if count != size {
        out.resize(start, 0);
        return FILE_READ_FAILED;
    }
    out.resize(start + count, 0);
    return FILE_READ_OK;
}
