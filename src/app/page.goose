import src.constants.limits;
import src.app.context;
import src.app.session;
import src.app.csrf;
import src.app.templates;
import std;
namespace web;

// Page state shared by layouts: the title, the CSRF token for forms, a flash message shown
// once, the request path and the signed-in user. Put a PageMeta field in a page's data struct
// and fill it with page_meta(c, title); templates read it as {{meta.title}} and so on.
// Sections on its bool field work too: {{#meta.has_flash}}...{{/meta.has_flash}}.

const FLASH_SESSION_KEY = "flash";
const FLASH_KIND_BYTES = 16;
const FLASH_MESSAGE_BYTES = 200;
const PAGE_TITLE_BYTES = 96;
const PAGE_PATH_BYTES = 256;
const PAGE_USER_BYTES = 64;
const PAGE_CSRF_BYTES = 96;

struct PageMeta {
    title: u8[..96] = "",
    csrf_token: u8[..96] = "",
    flash_kind: u8[..16] = "",
    flash_message: u8[..200] = "",
    has_flash: bool = false,
    path: u8[..256] = "",
    user: u8[..64] = "",
}

// A flash message taken from the session. present is false when none was waiting.
struct Flash { kind: u8[..16] = "", message: u8[..200] = "", present: bool = false }

// The first max bytes of text, so a field never overflows its capacity.
fn clip_text(text: const u8[:], max: i64) -> const u8[:] {
    return if text.len > max { text[..max] } else { text };
}

// Stores a flash message for the next page the client loads. kind names the style (for example
// "ok" or "error") and must not contain '|'. Needs the session middleware; false otherwise, or
// when the message is too long for the session.
fn flash(c: Ctx&, kind: const u8[:], message: const u8[:]) -> bool {
    if kind.len == 0 || kind.len > FLASH_KIND_BYTES || find(kind, "|") >= 0 { return false; }
    if message.len > FLASH_MESSAGE_BYTES { return false; }
    var text: u8[>..] = [];
    text.append(kind);
    text.push('|');
    text.append(message);
    return session_set(c, FLASH_SESSION_KEY, text[..]);
}

// The flash message waiting in the session, cleared so it is shown once. present is false when
// there is none. page_meta calls this, so a page built with it consumes the message.
fn take_flash(c: Ctx&) -> Flash {
    var taken = Flash { .. };
    let raw = session_get(c, FLASH_SESSION_KEY);
    if raw.len == 0 { return taken; }
    session_set(c, FLASH_SESSION_KEY, "");
    let bar = find(raw, "|");
    if bar < 0 { return taken; }
    taken.kind.append(clip_text(raw[..bar], FLASH_KIND_BYTES));
    taken.message.append(clip_text(raw[bar + 1..], FLASH_MESSAGE_BYTES));
    taken.present = true;
    return taken;
}

// The PageMeta for this request: title, CSRF token (when the csrf middleware runs), the taken
// flash message, the request path and the session's "user" value.
fn page_meta(c: Ctx&, title: const u8[:]) -> PageMeta {
    var meta = PageMeta { .. };
    meta.title.append(clip_text(title, PAGE_TITLE_BYTES));
    meta.csrf_token.append(clip_text(csrf_token(c), PAGE_CSRF_BYTES));
    let taken = take_flash(c);
    meta.has_flash = taken.present;
    meta.flash_kind.append(taken.kind[..]);
    meta.flash_message.append(taken.message[..]);
    meta.path.append(clip_text(path(c), PAGE_PATH_BYTES));
    meta.user.append(clip_text(session_get(c, "user"), PAGE_USER_BYTES));
    return meta;
}

// PageMeta is a struct field of a template struct, so its registrations are here (api.md, Templates):
// it prints nothing and cannot be repeated with each; dotted names reach its fields.
fn tpl_show(out: u8[>..]&, v: PageMeta&, escape: bool) -> bool { return false; }

fn tpl_each_value(out: u8[>..]&, body: const u8[:], v: PageMeta&, checking: bool, depth: i64, env: TplEnv&, count: i64&, result: TemplateResult&) -> bool {
    return tpl_fail(result, "each needs an array of structs");
}

fn tpl_show_sub(out: u8[>..]&, v: PageMeta&, tail: const u8[:], escape: bool, result: TemplateResult&) -> bool {
    return tpl_field(out, v, tail, escape, result);
}

fn tpl_flag_sub(data: PageMeta&, tail: const u8[:], flag: bool&, result: TemplateResult&) -> bool {
    return tpl_flag(data, tail, flag, result);
}
