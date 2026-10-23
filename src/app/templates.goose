import src.constants.http;
import src.constants.limits;
import src.http.errors;
import src.json.codec;
import src.app.context;
import json;
import std;
namespace web;

// Server-rendered HTML templates. A template is bytes (usually embed_file("views/page.html"),
// so a missing file is a compile error) and a struct value T whose fields it names. Docs: api.md.
//
// Grammar (tags are "{{" ... "}}"; "{{{" ... "}}}" for raw):
//   {{name}}              escaped value of field `name` (strings are HTML-escaped)
//   {{{name}}}            raw value (no escaping)
//   {{#name}}..{{/name}}  body shown when the bool field `name` is true
//   {{^name}}..{{/name}}  body shown when the bool field `name` is false
//   {{#each name}}..{{/each}}  body repeated for each element of the array field `name`;
//                         inside the body, names resolve against the element
//   {{! anything }}       comment, dropped from the output
// Whitespace around a tag name is ignored. Sections nest up to TEMPLATE_MAX_DEPTH levels.
// Field names are resolved at run time against fields<T>, so a name the struct lacks is an
// error, not a silent blank. Scalars (ints, floats, bool) print as text; u8 arrays print as
// their bytes. Struct-typed fields are not renderable; put struct arrays under each.

// Nesting limit for sections and each blocks.
const TEMPLATE_MAX_DEPTH = 8;
// Largest rendered page, matching the default response cap. Writes past it fail.
const TEMPLATE_MAX_OUTPUT_BYTES = 1048576;

// ok is false with the reason in error, e.g. "unknown field: title". The reason is cut to 128 bytes.
struct TemplateResult { ok: bool, error: u8[..128] }

// --- escaping ---------------------------------------------------------------------

// Escapes & < > " ' so text is safe in element content and quoted attribute values.
fn html_escape(out: u8[>..]&, text: const u8[:]) {
    for ch in text {
        if ch == '&' {
            out.append("&amp;");
        } else if ch == '<' {
            out.append("&lt;");
        } else if ch == '>' {
            out.append("&gt;");
        } else if ch == '"' {
            out.append("&quot;");
        } else if ch == '\'' {
            out.append("&#39;");
        } else {
            out.push(ch);
        }
    }
}

// --- errors and output -------------------------------------------------------------

fn tpl_fail(result: TemplateResult&, message: const u8[:]) -> bool {
    json_store(result.error, message);
    return false;
}

fn tpl_fail_name(result: TemplateResult&, prefix: const u8[:], name: const u8[:]) -> bool {
    let message = str(prefix, name);
    return tpl_fail(result, message[..]);
}

// Appends literal text or a value, refusing to grow the output past the cap.
fn tpl_text(out: u8[>..]&, s: const u8[:], result: TemplateResult&) -> bool {
    if s.len > TEMPLATE_MAX_OUTPUT_BYTES - out.len { return tpl_fail(result, "template output is too large"); }
    out.append(s);
    return true;
}

// Scalars print as their decimal or boolean text; the escape flag only matters for strings.
fn tpl_show(out: u8[>..]&, v: i64, escape: bool) -> bool { json::format_int(out, v); return true; }
fn tpl_show(out: u8[>..]&, v: i32, escape: bool) -> bool { json::format_int(out, v); return true; }
fn tpl_show(out: u8[>..]&, v: i16, escape: bool) -> bool { json::format_int(out, v); return true; }
fn tpl_show(out: u8[>..]&, v: i8, escape: bool) -> bool { json::format_int(out, v); return true; }
fn tpl_show(out: u8[>..]&, v: u64, escape: bool) -> bool { format(out, v); return true; }
fn tpl_show(out: u8[>..]&, v: u32, escape: bool) -> bool { json::format_int(out, v); return true; }
fn tpl_show(out: u8[>..]&, v: u16, escape: bool) -> bool { json::format_int(out, v); return true; }
fn tpl_show(out: u8[>..]&, v: u8, escape: bool) -> bool { json::format_int(out, v); return true; }
fn tpl_show(out: u8[>..]&, v: bool, escape: bool) -> bool { json::format_bool(out, v); return true; }
fn tpl_show(out: u8[>..]&, v: f32, escape: bool) -> bool { json::format_number(out, v); return true; }
fn tpl_show(out: u8[>..]&, v: f64, escape: bool) -> bool { json::format_number(out, v); return true; }
// Arrays: u8 arrays are text (escaped unless the tag was {{{raw}}}); arrays of structs are
// not printable. The generic overload is the one every array field reaches, because fields<T>
// visits all fields, so it must compile for struct arrays too.
fn tpl_text_value(out: u8[>..]&, v: const u8[:], escape: bool) -> bool {
    if escape { html_escape(out, v); } else { out.append(v); }
    return true;
}
fn tpl_text_value<E>(out: u8[>..]&, v: E[:], escape: bool) -> bool { return false; }
fn tpl_show<T>(out: u8[>..]&, v: T&, escape: bool) -> bool {
    return tpl_text_value(out, v[..], escape);
}

// --- field lookup -------------------------------------------------------------------

// {{name}} or {{{name}}}: the field's value.
fn tpl_field<T>(out: u8[>..]&, data: T&, name: const u8[:], escape: bool, result: TemplateResult&) -> bool {
    var found = false;
    var ok = true;
    const for <N, A> in fields<T> {
        if !found && name == N {
            found = true;
            ok = tpl_show(out, data.A, escape);
        }
    }
    if !found { return tpl_fail_name(result, "unknown field: ", name); }
    if !ok { return tpl_fail_name(result, "value cannot be printed: ", name); }
    // An escaped value can grow past its raw size, so the cap is checked after the write too.
    if out.len > TEMPLATE_MAX_OUTPUT_BYTES { return tpl_fail(result, "template output is too large"); }
    return true;
}

// Section test: only bool fields are sections. The flag says whether the field is true.
fn tpl_truthy(v: bool, is_bool: bool&) -> bool { is_bool = true; return v; }
fn tpl_truthy<T>(v: T&, is_bool: bool&) -> bool { is_bool = false; return false; }

fn tpl_flag<T>(data: T&, name: const u8[:], flag: bool&, result: TemplateResult&) -> bool {
    var found = false;
    var is_bool = false;
    const for <N, A> in fields<T> {
        if !found && name == N {
            found = true;
            flag = tpl_truthy(data.A, is_bool);
        }
    }
    if !found { return tpl_fail_name(result, "unknown field: ", name); }
    if !is_bool { return tpl_fail_name(result, "section needs a bool field: ", name); }
    return true;
}

// --- each ------------------------------------------------------------------------------

// {{#each name}}: array fields repeat their body. Scalars and text are not lists, so each
// of them fails here; the concrete overloads beat the generic array path below.
fn tpl_not_list(result: TemplateResult&) -> bool {
    return tpl_fail(result, "each needs an array of structs");
}
fn tpl_each_value(out: u8[>..]&, body: const u8[:], v: i64, checking: bool, depth: i64, result: TemplateResult&) -> bool { return tpl_not_list(result); }
fn tpl_each_value(out: u8[>..]&, body: const u8[:], v: i32, checking: bool, depth: i64, result: TemplateResult&) -> bool { return tpl_not_list(result); }
fn tpl_each_value(out: u8[>..]&, body: const u8[:], v: i16, checking: bool, depth: i64, result: TemplateResult&) -> bool { return tpl_not_list(result); }
fn tpl_each_value(out: u8[>..]&, body: const u8[:], v: i8, checking: bool, depth: i64, result: TemplateResult&) -> bool { return tpl_not_list(result); }
fn tpl_each_value(out: u8[>..]&, body: const u8[:], v: u64, checking: bool, depth: i64, result: TemplateResult&) -> bool { return tpl_not_list(result); }
fn tpl_each_value(out: u8[>..]&, body: const u8[:], v: u32, checking: bool, depth: i64, result: TemplateResult&) -> bool { return tpl_not_list(result); }
fn tpl_each_value(out: u8[>..]&, body: const u8[:], v: u16, checking: bool, depth: i64, result: TemplateResult&) -> bool { return tpl_not_list(result); }
fn tpl_each_value(out: u8[>..]&, body: const u8[:], v: u8, checking: bool, depth: i64, result: TemplateResult&) -> bool { return tpl_not_list(result); }
fn tpl_each_value(out: u8[>..]&, body: const u8[:], v: bool, checking: bool, depth: i64, result: TemplateResult&) -> bool { return tpl_not_list(result); }
fn tpl_each_value(out: u8[>..]&, body: const u8[:], v: f32, checking: bool, depth: i64, result: TemplateResult&) -> bool { return tpl_not_list(result); }
fn tpl_each_value(out: u8[>..]&, body: const u8[:], v: f64, checking: bool, depth: i64, result: TemplateResult&) -> bool { return tpl_not_list(result); }

// Text is a u8 array, not a list of structs.
fn tpl_each_seq(out: u8[>..]&, body: const u8[:], items: const u8[:], checking: bool, depth: i64, result: TemplateResult&) -> bool {
    return tpl_not_list(result);
}

// Each element is rendered with the same body, so every item carries the struct's own fields.
// Checking mode renders one default element, so the body is validated even for empty arrays.
recursive fn tpl_each_seq<E>(out: u8[>..]&, body: const u8[:], items: E[:], checking: bool, depth: i64, result: TemplateResult&) -> bool {
    if checking {
        var probe: E = E { .. };
        return tpl_block(out, body, probe, checking, depth + 1, result);
    }
    var i: i64 = 0;
    while i < items.len {
        if !tpl_block(out, body, items[i], checking, depth + 1, result) { return false; }
        i += 1;
    }
    return true;
}

recursive fn tpl_each_value<T>(out: u8[>..]&, body: const u8[:], v: T&, checking: bool, depth: i64, result: TemplateResult&) -> bool {
    return tpl_each_seq(out, body, v[..], checking, depth, result);
}

recursive fn tpl_each_field<T>(out: u8[>..]&, data: T&, name: const u8[:], body: const u8[:], checking: bool, depth: i64, result: TemplateResult&) -> bool {
    var found = false;
    var ok = true;
    const for <N, A> in fields<T> {
        if !found && name == N {
            found = true;
            ok = tpl_each_value(out, body, data.A, checking, depth, result);
        }
    }
    if !found { return tpl_fail_name(result, "unknown field: ", name); }
    return ok;
}

// --- scanning -----------------------------------------------------------------------------

fn tpl_space(c: u8) -> bool { return c == ' ' || c == '\t' || c == '\n' || c == '\r'; }

// Strips ASCII whitespace from both ends of a tag name.
fn tpl_trim(s: const u8[:]) -> const u8[:] {
    var first: i64 = 0;
    var last = s.len;
    while first < last && tpl_space(s[first]) { first += 1; }
    while last > first && tpl_space(s[last - 1]) { last -= 1; }
    return s[first..last];
}

// Index of the braces closing the tag that opens at `at`, or -1 when it never closes.
// raw is set for "{{{" tags, which close with "}}}".
fn tpl_tag_close(tpl: const u8[:], at: i64, raw: bool&) -> i64 {
    raw = at + 2 < tpl.len && tpl[at + 2] == '{';
    if raw {
        let close = find(tpl[at + 3..], "}}}");
        if close < 0 { return -1; }
        return at + 3 + close;
    }
    let close = find(tpl[at + 2..], "}}");
    if close < 0 { return -1; }
    return at + 2 + close;
}

// Finds the {{/closer}} that ends a section whose opening tag has just been read. Nested
// sections and each blocks are skipped by depth, so only the matching closer ends it.
// body is the offset where the closing tag starts and after the offset just past it,
// both relative to tpl.
fn tpl_section_end(tpl: const u8[:], closer: const u8[:], body: i64&, after: i64&, result: TemplateResult&) -> bool {
    var pos: i64 = 0;
    var depth: i64 = 0;
    while pos < tpl.len {
        let rel = find(tpl[pos..], "{{");
        if rel < 0 { break; }
        let at = pos + rel;
        var raw = false;
        let close = tpl_tag_close(tpl, at, raw);
        if close < 0 { return tpl_fail(result, "unclosed tag"); }
        let end = close + (if raw { 3 } else { 2 });
        if !raw {
            let tag = tpl_trim(tpl[at + 2..close]);
            if tag.len > 0 && (tag[0] == '#' || tag[0] == '^') {
                depth += 1;
            } else if tag.len > 0 && tag[0] == '/' {
                if depth == 0 {
                    if tpl_trim(tag[1..]) != closer { return tpl_fail(result, "section closing tag does not match its opening tag"); }
                    body = at;
                    after = end;
                    return true;
                }
                depth -= 1;
            }
        }
        pos = end;
    }
    return tpl_fail(result, "section is not closed");
}

// --- rendering -------------------------------------------------------------------------

// Renders the template against data. checking renders sections and each bodies regardless
// of their data, so check_template can validate every name without a real value.
recursive fn tpl_block<T>(out: u8[>..]&, tpl: const u8[:], data: T&, checking: bool, depth: i64, result: TemplateResult&) -> bool {
    if depth > TEMPLATE_MAX_DEPTH { return tpl_fail(result, "sections are nested too deeply"); }
    var pos: i64 = 0;
    while pos < tpl.len {
        let rel = find(tpl[pos..], "{{");
        let at = if rel < 0 { tpl.len } else { pos + rel };
        if !tpl_text(out, tpl[pos..at], result) { return false; }
        if at == tpl.len { break; }
        var raw = false;
        let close = tpl_tag_close(tpl, at, raw);
        if close < 0 { return tpl_fail(result, "unclosed tag"); }
        let open_len = if raw { 3 } else { 2 };
        let tag = tpl_trim(tpl[at + open_len..close]);
        pos = close + open_len;
        if raw {
            if !tpl_field(out, data, tag, false, result) { return false; }
            continue;
        }
        if tag.len == 0 { return tpl_fail(result, "empty tag"); }
        let kind = tag[0];
        if kind == '!' { continue; }
        if kind == '/' { return tpl_fail(result, "closing tag without an opening tag"); }
        if kind == '#' || kind == '^' {
            let name = tpl_trim(tag[1..]);
            let is_each = starts_with(name, "each ");
            let field = if is_each { tpl_trim(name[5..]) } else { name };
            let closer = if is_each { "each" } else { field };
            var body_end: i64 = 0;
            var after: i64 = 0;
            if !tpl_section_end(tpl[pos..], closer, body_end, after, result) { return false; }
            let body = tpl[pos..pos + body_end];
            let block_end = pos + after;
            if is_each {
                if !tpl_each_field(out, data, field, body, checking, depth, result) { return false; }
            } else {
                var flag = false;
                if !tpl_flag(data, field, flag, result) { return false; }
                let show = if kind == '#' { flag } else { !flag };
                if checking || show {
                    if !tpl_block(out, body, data, checking, depth + 1, result) { return false; }
                }
            }
            pos = block_end;
            continue;
        }
        if !tpl_field(out, data, tag, true, result) { return false; }
    }
    return true;
}

// Renders into out. On false, out is left as it was and result.error says why.
fn render_result<T>(out: u8[>..]&, template: const u8[:], data: T&) -> bool, TemplateResult {
    var result = TemplateResult { .. };
    if !valid_utf8(template) {
        tpl_fail(result, "template is not valid UTF-8");
        return false, result;
    }
    let start = out.len;
    if !tpl_block(out, template, data, false, 0, result) {
        out.pop_n(out.len - start);
        return false, result;
    }
    result.ok = true;
    return true, result;
}

// Renders the template into out. False on an unknown field, a malformed template, or output
// past TEMPLATE_MAX_OUTPUT_BYTES; out is then unchanged. Use render_result for the reason.
fn render<T>(out: u8[>..]&, template: const u8[:], data: T&) -> bool {
    let ok, result = render_result<T>(out, template, data);
    return ok;
}

// Startup check: validates every tag and section of the template against T, including the
// bodies of each blocks, without a real value. Returns true with an empty message, or false
// with the reason. Apps call it in main so template mistakes fail before the server starts.
fn check_template<T>(template: const u8[:]) -> bool, u8[>..] {
    var message: u8[>..] = [];
    if !valid_utf8(template) {
        message.append("template is not valid UTF-8");
        return false, message;
    }
    var out: u8[>..] = [];
    var data: T = T { .. };
    var result = TemplateResult { .. };
    if !tpl_block(out, template, data, true, 0, result) {
        message.append(result.error[..]);
        return false, message;
    }
    return true, message;
}

// Renders the template and writes it as text/html. A render failure writes 500 template_error
// with the reason, so a broken template shows up in the response instead of a partial page.
fn html_template<T>(c: Ctx&, template: const u8[:], data: T) {
    var out: u8[>..] = [];
    let ok, result = render_result<T>(out, template, data);
    if !ok {
        if valid_utf8(result.error[..]) {
            fail(c, HTTP_INTERNAL_SERVER_ERROR, "template_error", result.error[..]);
        } else {
            fail(c, HTTP_INTERNAL_SERVER_ERROR, "template_error", "template could not be rendered");
        }
        return;
    }
    write_body(c, CONTENT_TYPE_HTML, out[..]);
}
