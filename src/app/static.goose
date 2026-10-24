import src.constants.http;
import src.constants.limits;
import src.http.errors;
import src.http.headers;
import src.http.request;
import src.routing.router;
import src.app.context;
import src.sys.files;
import std;
namespace web;

// Static files as middleware: `fn static_files<Next>(c, url_prefix, directory)`. A GET or HEAD
// under url_prefix/ is answered from `directory` and Next is not called. Other requests pass
// through. A request under the prefix that is not a file answers 404 without calling Next, so
// GET routes under the same prefix are shadowed.
//
// Mapping: the path after the prefix is percent-decoded and checked segment by segment. A
// trailing '/' or a directory serves its index.html. Refused with 400 invalid_path: encoded or
// raw '/', '\\' and NUL (%2F, %5C, %00), control bytes, empty segments (leading "//"), "." and
// "..". Refused with 404: hidden entries (a segment starting with '.'), missing files, and
// directories without index.html.
//
// Size and blocking: the file's size is read from stat before any byte is read. A file over
// the response cap (c.response.max_body) is refused with 500 file_too_large and is never read. Otherwise at most
// size + 1 bytes are read (see read_bounded_file), on the reactor thread. A file that cannot be
// read answers 500 file_read_failed. Keep served trees small and trusted. Symbolic links are followed
// only when their real target lies inside the directory; a link that leaves it answers 404.

const CONTENT_TYPE_CSS = "text/css; charset=utf-8";
const CONTENT_TYPE_JS = "text/javascript; charset=utf-8";
const CONTENT_TYPE_SVG = "image/svg+xml";
const CONTENT_TYPE_PNG = "image/png";
const CONTENT_TYPE_JPEG = "image/jpeg";
const CONTENT_TYPE_GIF = "image/gif";
const CONTENT_TYPE_ICO = "image/x-icon";
const CONTENT_TYPE_WASM = "application/wasm";
const HEADER_NOSNIFF_NAME = "X-Content-Type-Options";
const HEADER_NOSNIFF_VALUE = "nosniff";

// Content-Type from the last extension after the final '/'; unknown or missing extensions are
// application/octet-stream. Extension matching is case-insensitive.
fn static_content_type(path: const u8[:]) -> const u8[:] {
    var start = path.len;
    while start > 0 && path[start - 1] != '.' && path[start - 1] != '/' { start -= 1; }
    if start == 0 || path[start - 1] != '.' { return CONTENT_TYPE_OCTET_STREAM; }
    let ext = path[start..];
    if equal_header(ext, "html") || equal_header(ext, "htm") { return CONTENT_TYPE_HTML; }
    if equal_header(ext, "css") { return CONTENT_TYPE_CSS; }
    if equal_header(ext, "js") || equal_header(ext, "mjs") { return CONTENT_TYPE_JS; }
    if equal_header(ext, "json") { return CONTENT_TYPE_JSON; }
    if equal_header(ext, "svg") { return CONTENT_TYPE_SVG; }
    if equal_header(ext, "png") { return CONTENT_TYPE_PNG; }
    if equal_header(ext, "jpg") || equal_header(ext, "jpeg") { return CONTENT_TYPE_JPEG; }
    if equal_header(ext, "gif") { return CONTENT_TYPE_GIF; }
    if equal_header(ext, "ico") { return CONTENT_TYPE_ICO; }
    if equal_header(ext, "txt") { return CONTENT_TYPE_TEXT; }
    if equal_header(ext, "wasm") { return CONTENT_TYPE_WASM; }
    return CONTENT_TYPE_OCTET_STREAM;
}

// Percent-decodes one request path. Only a raw '/' separates segments: encoded separators,
// backslashes, NUL and control bytes are refused. Returns false on any refusal.
fn static_decode(raw: const u8[:], out: u8[>..]&) -> bool {
    var pos: i64 = 0;
    while pos < raw.len {
        var ch = raw[pos];
        if ch == '\\' { return false; }
        if ch == '%' {
            if pos + 2 >= raw.len { return false; }
            let hi = query_hex(raw[pos + 1]);
            let lo = query_hex(raw[pos + 2]);
            if hi < 0 || lo < 0 { return false; }
            ch = (hi * 16 + lo) as u8;
            if ch == '/' || ch == '\\' || ch == 0 || ch < 32 || ch == 127 { return false; }
            pos += 2;
        }
        out.push(ch);
        pos += 1;
    }
    return true;
}

// Checks the decoded relative path. Empty means the directory itself. Otherwise every segment
// must be nonempty (except one trailing empty segment from a trailing '/'), not "." or "..",
// and not hidden. Returns HTTP_OK, HTTP_BAD_REQUEST or HTTP_NOT_FOUND.
fn static_segments(rel: const u8[:]) -> i32 {
    if rel.len == 0 { return HTTP_OK; }
    var start: i64 = 0;
    loop {
        let slash = find(rel[start..], "/");
        let end = if slash < 0 { rel.len } else { start + slash };
        let seg = rel[start..end];
        if seg.len == 0 {
            if end == rel.len && start > 0 { return HTTP_OK; }
            return HTTP_BAD_REQUEST;
        }
        if seg == "." || seg == ".." { return HTTP_BAD_REQUEST; }
        if seg[0] == '.' { return HTTP_NOT_FOUND; }
        if end == rel.len { return HTTP_OK; }
        start = end + 1;
    }
}

// Maps a request path after the prefix to a file under `directory`. On HTTP_OK, `full` holds
// the file path. Directories map to their index.html; a missing file is 404.
fn static_resolve(rel: const u8[:], directory: const u8[:], full: u8[>..]&) -> i32 {
    var decoded: u8[>..] = [];
    if !static_decode(rel, decoded) { return HTTP_BAD_REQUEST; }
    let shape = static_segments(decoded[..]);
    if shape != HTTP_OK { return shape; }
    format(full, directory, "/", decoded[..]);
    if decoded.len == 0 || decoded[decoded.len - 1] == '/' {
        full.append("index.html");
    } else if file_kind(full[..]) == FILE_KIND_DIRECTORY {
        full.append("/index.html");
    }
    if file_kind(full[..]) != FILE_KIND_REGULAR { return HTTP_NOT_FOUND; }
    // A symbolic link that resolves outside the served directory is treated as missing.
    if !file_within(directory, full[..]) { return HTTP_NOT_FOUND; }
    return HTTP_OK;
}

// True when path is url_prefix followed by '/' and more (or nothing) after it.
fn static_under(path: const u8[:], base: const u8[:]) -> bool {
    if path.len <= base.len { return false; }
    if path[..base.len] != base { return false; }
    return path[base.len] == '/';
}

// Middleware for files under url_prefix, served from directory. See the comment above.
fn static_files<Next>(c: Ctx&, url_prefix: const u8[:], directory: const u8[:]) {
    assert(url_prefix.len > 0 && url_prefix[0] == '/');
    assert(directory.len > 0);
    var base = url_prefix;
    if base[base.len - 1] == '/' { base = base[..base.len - 1]; }
    let method = c.method();
    let path = target_path(c.request.target);
    if (method != METHOD_GET && method != METHOD_HEAD) || !static_under(path, base) {
        Next();
        return;
    }
    var full: u8[>..] = [];
    let status = static_resolve(path[base.len + 1..], directory, full);
    if status == HTTP_BAD_REQUEST {
        fail(c, HTTP_BAD_REQUEST, "invalid_path", "Path is not a valid static file path");
        return;
    }
    if status != HTTP_OK {
        fail(c, HTTP_NOT_FOUND, "not_found", "File not found");
        return;
    }
    var body: u8[>..] = [];
    let read = read_bounded_file(full[..], c.response.max_body, body);
    if read == FILE_READ_MISSING {
        fail(c, HTTP_NOT_FOUND, "not_found", "File not found");
        return;
    }
    if read == FILE_READ_TOO_LARGE {
        fail(c, HTTP_INTERNAL_SERVER_ERROR, "file_too_large", "Static file exceeds the response body limit");
        return;
    }
    if read != FILE_READ_OK {
        fail(c, HTTP_INTERNAL_SERVER_ERROR, "file_read_failed", "Static file could not be read");
        return;
    }
    c.set(HEADER_NOSNIFF_NAME, HEADER_NOSNIFF_VALUE);
    write_body(c, static_content_type(full[..]), body[..]);
}
