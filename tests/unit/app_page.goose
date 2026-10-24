// Page state: flash messages that show once, and PageMeta filled from the request.
import goose_web from "../..";
import std;

var shared_response = web::response();
var shared_scratch = web::AppScratch { .. };

fn test_flash() {
    var c = web::new_ctx(web::Request { method: "GET", target: "/a?x=1", body: "", raw_headers: "Host: x\r\n" }, shared_response, shared_scratch);
    // Without the session middleware nothing can be stored.
    assert(!web::flash(c, "ok", "Saved"));
    assert(!web::take_flash(c).present);

    c.session_state.active = true;
    assert(web::flash(c, "ok", "Saved"));
    // Bad kinds and over-long messages are refused and leave the stored message alone.
    assert(!web::flash(c, "", "x"));
    assert(!web::flash(c, "a|b", "x"));
    var long: u8[>..] = [];
    for i in 201 { long.push('m'); }
    assert(!web::flash(c, "ok", long[..]));

    let taken = web::take_flash(c);
    assert(taken.present && taken.kind[..] == "ok" && taken.message[..] == "Saved");
    // Shown once: the second take finds nothing.
    assert(!web::take_flash(c).present);

    // The message may contain the separator; the kind ends at the first bar.
    assert(web::flash(c, "error", "a|b"));
    let piped = web::take_flash(c);
    assert(piped.present && piped.kind[..] == "error" && piped.message[..] == "a|b");
}

fn test_page_meta() {
    var c = web::new_ctx(web::Request { method: "GET", target: "/a?x=1", body: "", raw_headers: "Host: x\r\n" }, shared_response, shared_scratch);
    c.session_state.active = true;
    c.csrf_state.token = "token.tag";
    assert(web::flash(c, "ok", "Saved"));
    assert(web::session_set(c, "user", "ada"));

    let meta = web::page_meta(c, "Home");
    assert(meta.title[..] == "Home");
    assert(meta.csrf_token[..] == "token.tag");
    assert(meta.has_flash && meta.flash_kind[..] == "ok" && meta.flash_message[..] == "Saved");
    assert(meta.path[..] == "/a");
    assert(meta.user[..] == "ada");

    // The flash went with the first page; a second page sees none.
    let again = web::page_meta(c, "Next");
    assert(!again.has_flash && again.flash_message.len == 0);

    // Over-long values are cut to their fields, not overflowed.
    var title: u8[>..] = [];
    for i in 200 { title.push('t'); }
    let cut = web::page_meta(c, title[..]);
    assert(cut.title.len == 96);
}

fn main() {
    test_flash();
    test_page_meta();
    print("App page tests passed: flash shows once, refused kinds and sizes, PageMeta fields");
}
