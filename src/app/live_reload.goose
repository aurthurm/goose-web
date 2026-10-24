import src.constants.http;
import src.constants.limits;
import src.http.response;
import src.app.context;
import src.sys.process;
import std;
namespace web;

// Development live reload (scripts/dev.py). `live_reload(c) { next }` is middleware: after the
// inner handlers ran, a text/html response gets `<script src="URL"></script>` before its last
// </body> (appended when there is none). The URL is the script_url argument, or else the value of
// GOOSE_WEB_LIVE_RELOAD, read once per process. Unset, empty or unsafe means the middleware only
// calls Next, so a production build pays one flag check per request.
const LIVE_RELOAD_ENV = "GOOSE_WEB_LIVE_RELOAD";
const LIVE_RELOAD_URL_MAX_BYTES = 256;
const LIVE_RELOAD_HTML_TYPE = "text/html";
const LIVE_RELOAD_BODY_CLOSE = "</body>";

var live_reload_read: bool = false;
var live_reload_url: u8[LIVE_RELOAD_URL_MAX_BYTES] = [0; LIVE_RELOAD_URL_MAX_BYTES];
var live_reload_length: i64 = 0;

// A script URL is written inside a double-quoted attribute, so it must be printable and free of
// quotes, angle brackets, backslashes and spaces.
fn live_reload_url_valid(url: const u8[:]) -> bool {
    if url.len == 0 || url.len > LIVE_RELOAD_URL_MAX_BYTES { return false; }
    for ch in url {
        if ch <= 32 || ch == 127 || ch == '"' || ch == '\'' || ch == '<' || ch == '>' || ch == '\\' { return false; }
    }
    return true;
}

// The environment URL, read on the first request. Empty when unset or invalid.
fn live_reload_env() -> const u8[:] {
    if !live_reload_read {
        live_reload_read = true;
        let length = getenv_into(LIVE_RELOAD_ENV, live_reload_url[..]);
        if length > 0 && live_reload_url_valid(live_reload_url[..length]) {
            live_reload_length = length;
        }
    }
    return live_reload_url[..live_reload_length];
}

// Index of the last "</body>" in body, or -1.
fn live_reload_body_close(body: const u8[:]) -> i64 {
    let width = LIVE_RELOAD_BODY_CLOSE.len;
    if body.len < width { return -1; }
    var at = body.len - width;
    while at >= 0 {
        if body[at..at + width] == LIVE_RELOAD_BODY_CLOSE { return at; }
        at -= 1;
    }
    return -1;
}

// Rewrites a text/html response so it loads script_url. Other responses, SSE streams and
// rewrites that would exceed max_body leave the response unchanged. Call after the handler ran.
fn inject_live_reload(c: Ctx&, script_url: const u8[:]) {
    if !live_reload_url_valid(script_url) { return; }
    if c.response.sse || !starts_with(c.response.content_type[..], LIVE_RELOAD_HTML_TYPE) { return; }
    let body = body_of(c.response);
    let at = live_reload_body_close(body);
    var tag: u8[>..] = [];
    format(tag, "<script src=\"", script_url, "\"></script>");
    var out: u8[>..] = [];
    if at < 0 {
        out.append(body);
        out.append(tag[..]);
    } else {
        out.append(body[..at]);
        out.append(tag[..]);
        out.append(body[at..]);
    }
    // set_body appends, so the bytes the old body still holds count against max_body too.
    if out.len > c.response.max_body - c.response.body.len { return; }
    assert(set_body(c.response, out[..]));
}

// Middleware. script_url overrides GOOSE_WEB_LIVE_RELOAD when nonempty (tests use it).
fn live_reload<Next>(c: Ctx&, script_url: const u8[:] = "") {
    Next();
    if script_url.len > 0 {
        inject_live_reload(c, script_url);
    } else {
        inject_live_reload(c, live_reload_env());
    }
}
