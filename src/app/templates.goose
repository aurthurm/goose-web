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
//   {{meta.title}}        dotted: a field of a registered struct field (see "Struct fields" below)
//   {{#name}}..{{/name}}  body shown when the bool field `name` is true (dotted names work too)
//   {{^name}}..{{/name}}  body shown when the bool field `name` is false
//   {{#each name}}..{{/each}}  body repeated for each element of the array field `name`;
//                         inside the body, names resolve against the element
//   {{#each name}}..{{else}}..{{/each}}  the else part is shown when the array is empty
//   {{@index}} {{@count}} {{@first}} {{@last}}  loop values, inside each only
//   {{#@first}}..{{/@first}}   loop flags as sections (@first, @last)
//   {{$name}}..{{/name}}  a named block. In a page it defines the block (not shown in place);
//                         in a layout it is a slot: the page's block, else this default body
//   {{> name}}            a partial from the registry (add_template), rendered with the same data
//   {{> content}}         in a layout only: the rendered page body
//   {{! anything }}       comment, dropped from the output
// Whitespace around a tag name is ignored. Sections nest up to TEMPLATE_MAX_DEPTH levels, and
// partials count toward that depth. A partial that includes itself fails at render or check.
// Field names are resolved at run time against fields<T>, so a name the struct lacks is an
// error, not a silent blank. Scalars (ints, floats, bool) print as text; u8 arrays print as
// their bytes. Arrays of structs are for each.
//
// Struct fields: Goose cannot tell a struct from a fixed string in one generic body, so a struct
// used as a field of a template struct needs its overloads in namespace web (see api.md, Templates):
//   tpl_show(out, v: S&, escape) -> bool     refuse printing (return false)
//   tpl_each_value(out, body, v: S&, checking, depth, env, count&, result) -> bool  refuse each
//   tpl_show_sub(out, v: S&, tail, escape, result) -> bool    dotted reads: tpl_field(out, v, tail, ...)
//   tpl_flag_sub(v: S&, tail, flag&, result) -> bool          dotted sections: tpl_flag(v, tail, flag&, ...)
// page.goose registers PageMeta this way.

// Nesting limit for sections, each blocks and partials.
const TEMPLATE_MAX_DEPTH = 8;
// Largest rendered page, matching the default response cap. Writes past it fail.
const TEMPLATE_MAX_OUTPUT_BYTES = 1048576;
// Registry capacity: partials per program, bytes per partial, and name length.
const TEMPLATE_MAX_PARTIALS = 32;
const TEMPLATE_MAX_PARTIAL_BYTES = 65536;
const TEMPLATE_MAX_NAME_BYTES = 32;
// Named blocks one page may define.
const TEMPLATE_MAX_BLOCKS = 16;
// Render modes. PLAIN renders blocks inline. PAGE renders the page body and drops its block
// definitions. LAYOUT places the page body (content) and the page's blocks into the layout.
const TPL_PLAIN = 0;
const TPL_PAGE = 1;
const TPL_LAYOUT = 2;
const TPL_CONTENT = "content";

// ok is false with the reason in error, e.g. "unknown field: title". The reason is cut to 128 bytes.
struct TemplateResult { ok: bool, error: u8[..128] }

// Named partials. Built once at startup: var views = web::templates(); add_template(...).
struct Templates { count: i64 = 0, names: const u8[:][TEMPLATE_MAX_PARTIALS], bodies: const u8[:][TEMPLATE_MAX_PARTIALS] }

// The blocks a page defines, collected before the layout is rendered.
struct PageBlocks { count: i64 = 0, names: const u8[:][TEMPLATE_MAX_BLOCKS], bodies: const u8[:][TEMPLATE_MAX_BLOCKS] }

// The loop an each body is running in. Inactive outside each.
struct LoopFrame { active: bool = false, index: i64 = 0, count: i64 = 0 }

// Shared state of one render: the registry, the page's blocks, the mode, the page body for
// {{> content}}, and the partials being rendered (for cycle detection).
struct TplEnv {
    partials: Templates&,
    blocks: PageBlocks&,
    mode: i64,
    content: const u8[:],
    active: i64[TEMPLATE_MAX_DEPTH],
    active_count: i64,
}

// --- registry -----------------------------------------------------------------------------

// An empty registry.
fn templates() -> Templates {
    return Templates { .. };
}

// Name characters: no whitespace and none of the tag markers.
fn tpl_name_ok(name: const u8[:]) -> bool {
    if name.len == 0 || name.len > TEMPLATE_MAX_NAME_BYTES { return false; }
    for ch in name {
        if ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r' { return false; }
        if ch == '{' || ch == '}' || ch == '#' || ch == '^' || ch == '/' || ch == '$' || ch == '>' || ch == '!' || ch == '@' { return false; }
    }
    return true;
}

// Registers a partial under name. False, with the registry unchanged, when it is full, the name
// is invalid or taken (or "content", which a layout reserves), or the body is too large or not
// UTF-8. Bodies are borrowed, so pass embed_file("...") or another static text.
fn add_template(views: Templates&, name: const u8[:], body: const u8[:]) -> bool {
    if views.count == TEMPLATE_MAX_PARTIALS { return false; }
    if !tpl_name_ok(name) || name == TPL_CONTENT { return false; }
    if body.len > TEMPLATE_MAX_PARTIAL_BYTES || !valid_utf8(body) { return false; }
    for i in views.count {
        if views.names[i] == name { return false; }
    }
    views.names[views.count] = name;
    views.bodies[views.count] = body;
    views.count += 1;
    return true;
}

// Registry index of the partial called name, or -1.
fn tpl_partial_index(views: Templates&, name: const u8[:]) -> i64 {
    for i in views.count {
        if views.names[i] == name { return i; }
    }
    return -1;
}

fn tpl_page_block(blocks: PageBlocks&, name: const u8[:]) -> const u8[:], bool {
    for i in blocks.count {
        if blocks.names[i] == name { return blocks.bodies[i], true; }
    }
    return "", false;
}

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

// Dotted reads through a field of a struct type. The generic overloads refuse, so any type
// without a registration fails with the path name; a registered struct overrides them.
fn tpl_show_sub<U>(out: u8[>..]&, v: U&, tail: const u8[:], escape: bool, result: TemplateResult&) -> bool {
    return tpl_fail_name(result, "no registered struct for: ", tail);
}

// --- field lookup -------------------------------------------------------------------

// Dotted sections and values: head names a field of T, tail the rest of the path.
fn tpl_sub_field<T>(out: u8[>..]&, data: T&, head: const u8[:], tail: const u8[:], escape: bool, result: TemplateResult&) -> bool {
    var found = false;
    var ok = true;
    const for <N, A> in fields<T> {
        if !found && head == N {
            found = true;
            ok = tpl_show_sub(out, data.A, tail, escape, result);
        }
    }
    if !found { return tpl_fail_name(result, "unknown field: ", head); }
    return ok;
}

// {{name}}, {{{name}}} or {{name.tail}}: the field's value.
fn tpl_field<T>(out: u8[>..]&, data: T&, name: const u8[:], escape: bool, result: TemplateResult&) -> bool {
    let dot = find(name, ".");
    if dot >= 0 { return tpl_sub_field(out, data, name[..dot], name[dot + 1..], escape, result); }
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

// Dotted section flags reach a registered struct through tpl_flag_sub.
fn tpl_flag_sub<U>(data: U&, tail: const u8[:], flag: bool&, result: TemplateResult&) -> bool {
    return tpl_fail_name(result, "no registered struct for: ", tail);
}

fn tpl_flag<T>(data: T&, name: const u8[:], flag: bool&, result: TemplateResult&) -> bool {
    let dot = find(name, ".");
    if dot >= 0 { return tpl_flag_sub_field(data, name[..dot], name[dot + 1..], flag, result); }
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

fn tpl_flag_sub_field<T>(data: T&, head: const u8[:], tail: const u8[:], flag: bool&, result: TemplateResult&) -> bool {
    var found = false;
    var ok = true;
    const for <N, A> in fields<T> {
        if !found && head == N {
            found = true;
            ok = tpl_flag_sub(data.A, tail, flag, result);
        }
    }
    if !found { return tpl_fail_name(result, "unknown field: ", head); }
    return ok;
}

// --- loop values ----------------------------------------------------------------------

// {{#@first}} and {{#@last}}: the flag for the loop the body is in.
fn tpl_loop_flag(name: const u8[:], frame: LoopFrame, flag: bool&, result: TemplateResult&) -> bool {
    if !frame.active { return tpl_fail(result, "loop values are only inside each"); }
    if name == "first" {
        flag = frame.index == 0;
        return true;
    }
    if name == "last" {
        flag = frame.index == frame.count - 1;
        return true;
    }
    return tpl_fail_name(result, "unknown loop value: ", name);
}

// {{@index}}, {{@count}}, {{@first}} and {{@last}}.
fn tpl_loop_value(out: u8[>..]&, name: const u8[:], frame: LoopFrame, result: TemplateResult&) -> bool {
    if !frame.active { return tpl_fail(result, "loop values are only inside each"); }
    if name == "index" {
        json::format_int(out, frame.index);
        return true;
    }
    if name == "count" {
        json::format_int(out, frame.count);
        return true;
    }
    var flag = false;
    if !tpl_loop_flag(name, frame, flag, result) { return false; }
    json::format_bool(out, flag);
    return true;
}

// --- each ------------------------------------------------------------------------------

// {{#each name}}: array fields repeat their body. Scalars and text are not lists, so each
// of them fails here; the concrete overloads beat the generic array path below.
fn tpl_not_list(result: TemplateResult&) -> bool {
    return tpl_fail(result, "each needs an array of structs");
}
fn tpl_each_value(out: u8[>..]&, body: const u8[:], v: i64, checking: bool, depth: i64, env: TplEnv&, count: i64&, result: TemplateResult&) -> bool { return tpl_not_list(result); }
fn tpl_each_value(out: u8[>..]&, body: const u8[:], v: i32, checking: bool, depth: i64, env: TplEnv&, count: i64&, result: TemplateResult&) -> bool { return tpl_not_list(result); }
fn tpl_each_value(out: u8[>..]&, body: const u8[:], v: i16, checking: bool, depth: i64, env: TplEnv&, count: i64&, result: TemplateResult&) -> bool { return tpl_not_list(result); }
fn tpl_each_value(out: u8[>..]&, body: const u8[:], v: i8, checking: bool, depth: i64, env: TplEnv&, count: i64&, result: TemplateResult&) -> bool { return tpl_not_list(result); }
fn tpl_each_value(out: u8[>..]&, body: const u8[:], v: u64, checking: bool, depth: i64, env: TplEnv&, count: i64&, result: TemplateResult&) -> bool { return tpl_not_list(result); }
fn tpl_each_value(out: u8[>..]&, body: const u8[:], v: u32, checking: bool, depth: i64, env: TplEnv&, count: i64&, result: TemplateResult&) -> bool { return tpl_not_list(result); }
fn tpl_each_value(out: u8[>..]&, body: const u8[:], v: u16, checking: bool, depth: i64, env: TplEnv&, count: i64&, result: TemplateResult&) -> bool { return tpl_not_list(result); }
fn tpl_each_value(out: u8[>..]&, body: const u8[:], v: u8, checking: bool, depth: i64, env: TplEnv&, count: i64&, result: TemplateResult&) -> bool { return tpl_not_list(result); }
fn tpl_each_value(out: u8[>..]&, body: const u8[:], v: bool, checking: bool, depth: i64, env: TplEnv&, count: i64&, result: TemplateResult&) -> bool { return tpl_not_list(result); }
fn tpl_each_value(out: u8[>..]&, body: const u8[:], v: f32, checking: bool, depth: i64, env: TplEnv&, count: i64&, result: TemplateResult&) -> bool { return tpl_not_list(result); }
fn tpl_each_value(out: u8[>..]&, body: const u8[:], v: f64, checking: bool, depth: i64, env: TplEnv&, count: i64&, result: TemplateResult&) -> bool { return tpl_not_list(result); }

// Text is a u8 array, not a list of structs.
fn tpl_each_seq(out: u8[>..]&, body: const u8[:], items: const u8[:], checking: bool, depth: i64, env: TplEnv&, count: i64&, result: TemplateResult&) -> bool {
    return tpl_not_list(result);
}

// Each element is rendered with the same body, so every item carries the struct's own fields,
// and @index and the others describe the element's place. Checking mode renders one default
// element, so the body is validated even for empty arrays. count is the array length.
recursive fn tpl_each_seq<E>(out: u8[>..]&, body: const u8[:], items: E[:], checking: bool, depth: i64, env: TplEnv&, count: i64&, result: TemplateResult&) -> bool {
    count = items.len;
    if checking {
        var probe: E = E { .. };
        return tpl_block(out, body, probe, checking, depth + 1, env, LoopFrame { active: true, index: 0, count: 1 }, result);
    }
    var i: i64 = 0;
    while i < items.len {
        if !tpl_block(out, body, items[i], checking, depth + 1, env, LoopFrame { active: true, index: i, count: items.len }, result) { return false; }
        i += 1;
    }
    return true;
}

recursive fn tpl_each_value<T>(out: u8[>..]&, body: const u8[:], v: T&, checking: bool, depth: i64, env: TplEnv&, count: i64&, result: TemplateResult&) -> bool {
    return tpl_each_seq(out, body, v[..], checking, depth, env, count, result);
}

// {{#each name}}body{{else}}empty{{/each}}: else_body is shown when the array is empty.
recursive fn tpl_each_field<T>(out: u8[>..]&, data: T&, name: const u8[:], body: const u8[:], else_body: const u8[:], has_else: bool, checking: bool, depth: i64, env: TplEnv&, frame: LoopFrame, result: TemplateResult&) -> bool {
    var found = false;
    var ok = true;
    var count: i64 = 0;
    const for <N, A> in fields<T> {
        if !found && name == N {
            found = true;
            ok = tpl_each_value(out, body, data.A, checking, depth, env, count, result);
        }
    }
    if !found { return tpl_fail_name(result, "unknown field: ", name); }
    if !ok { return false; }
    if has_else && (checking || count == 0) {
        return tpl_block(out, else_body, data, checking, depth + 1, env, frame, result);
    }
    return true;
}

// --- partials and blocks --------------------------------------------------------------

// {{> name}}: renders the registered partial with the current data. The active list catches a
// partial that includes itself, and the depth limit catches longer cycles.
recursive fn tpl_partial<T>(out: u8[>..]&, name: const u8[:], data: T&, checking: bool, depth: i64, env: TplEnv&, frame: LoopFrame, result: TemplateResult&) -> bool {
    if depth + 1 > TEMPLATE_MAX_DEPTH { return tpl_fail(result, "partials are nested too deeply"); }
    let index = tpl_partial_index(env.partials, name);
    if index < 0 { return tpl_fail_name(result, "unknown partial: ", name); }
    for i in env.active_count {
        if env.active[i] == index { return tpl_fail_name(result, "partial includes itself: ", name); }
    }
    env.active[env.active_count] = index;
    env.active_count += 1;
    let ok = tpl_block(out, env.partials.bodies[index], data, checking, depth + 1, env, frame, result);
    env.active_count -= 1;
    return ok;
}

// A {{$name}}body{{/name}} tag. A page drops its definitions (they are collected up front); a
// layout places the page's block of that name, else the default body; plain text shows the body.
recursive fn tpl_block_slot<T>(out: u8[>..]&, name: const u8[:], body: const u8[:], data: T&, checking: bool, depth: i64, env: TplEnv&, frame: LoopFrame, result: TemplateResult&) -> bool {
    if env.mode == TPL_PAGE {
        if !checking { return true; }
        return tpl_block(out, body, data, checking, depth + 1, env, frame, result);
    }
    if env.mode == TPL_PLAIN {
        return tpl_block(out, body, data, checking, depth + 1, env, frame, result);
    }
    let page_body, found = tpl_page_block(env.blocks, name);
    if found { return tpl_block(out, page_body, data, checking, depth + 1, env, frame, result); }
    return tpl_block(out, body, data, checking, depth + 1, env, frame, result);
}

// Index and length of the {{else}} tag at the top level of an each body, or false when none.
fn tpl_else_split(body: const u8[:], at: i64&, after: i64&) -> bool {
    var pos: i64 = 0;
    var depth: i64 = 0;
    while pos < body.len {
        let rel = find(body[pos..], "{{");
        if rel < 0 { return false; }
        let start = pos + rel;
        var raw = false;
        let close = tpl_tag_close(body, start, raw);
        if close < 0 { return false; }
        let end = close + (if raw { 3 } else { 2 });
        if !raw {
            let tag = tpl_trim(body[start + 2..close]);
            if tag.len > 0 && (tag[0] == '#' || tag[0] == '^' || tag[0] == '$') {
                depth += 1;
            } else if tag.len > 0 && tag[0] == '/' {
                depth -= 1;
            } else if depth == 0 && tag == "else" {
                at = start;
                after = end;
                return true;
            }
        }
        pos = end;
    }
    return false;
}

// Collects the blocks a page defines, at any depth, into blocks. A block name may appear once.
fn collect_blocks(page: const u8[:], blocks: PageBlocks&, result: TemplateResult&) -> bool {
    var pos: i64 = 0;
    while pos < page.len {
        let rel = find(page[pos..], "{{");
        if rel < 0 { break; }
        let at = pos + rel;
        var raw = false;
        let close = tpl_tag_close(page, at, raw);
        if close < 0 { return tpl_fail(result, "unclosed tag"); }
        let end = close + (if raw { 3 } else { 2 });
        if !raw {
            let tag = tpl_trim(page[at + 2..close]);
            if tag.len > 0 && tag[0] == '$' {
                let name = tpl_trim(tag[1..]);
                if !tpl_name_ok(name) { return tpl_fail_name(result, "invalid block name: ", name); }
                var body_end: i64 = 0;
                var after: i64 = 0;
                if !tpl_section_end(page[end..], name, body_end, after, result) { return false; }
                let earlier, taken = tpl_page_block(blocks, name);
                if taken { return tpl_fail_name(result, "block defined twice: ", name); }
                if blocks.count == TEMPLATE_MAX_BLOCKS { return tpl_fail(result, "too many blocks in one page"); }
                blocks.names[blocks.count] = name;
                blocks.bodies[blocks.count] = page[end..end + body_end];
                blocks.count += 1;
                pos = end + after;
                continue;
            }
        }
        pos = end;
    }
    return true;
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
// sections, each blocks and blocks are skipped by depth, so only the matching closer ends it.
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
            if tag.len > 0 && (tag[0] == '#' || tag[0] == '^' || tag[0] == '$') {
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
// of their data, so check_template can validate every name without a real value. frame is the
// loop the template is in, if any.
recursive fn tpl_block<T>(out: u8[>..]&, tpl: const u8[:], data: T&, checking: bool, depth: i64, env: TplEnv&, frame: LoopFrame, result: TemplateResult&) -> bool {
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
        if kind == '>' {
            let name = tpl_trim(tag[1..]);
            if name == TPL_CONTENT {
                if env.mode != TPL_LAYOUT { return tpl_fail(result, "content is only in a layout"); }
                if !tpl_text(out, env.content, result) { return false; }
            } else if !tpl_partial(out, name, data, checking, depth, env, frame, result) {
                return false;
            }
            continue;
        }
        if kind == '$' {
            let name = tpl_trim(tag[1..]);
            var body_end: i64 = 0;
            var after: i64 = 0;
            if !tpl_section_end(tpl[pos..], name, body_end, after, result) { return false; }
            let body = tpl[pos..pos + body_end];
            pos += after;
            if !tpl_block_slot(out, name, body, data, checking, depth, env, frame, result) { return false; }
            continue;
        }
        if kind == '@' {
            if !tpl_loop_value(out, tpl_trim(tag[1..]), frame, result) { return false; }
            continue;
        }
        if tag == "else" { return tpl_fail(result, "else is only inside each"); }
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
                var else_at: i64 = 0;
                var else_after: i64 = 0;
                let has_else = tpl_else_split(body, else_at, else_after);
                let each_body = if has_else { body[..else_at] } else { body };
                let else_body = if has_else { body[else_after..] } else { body[..0] };
                if !tpl_each_field(out, data, field, each_body, else_body, has_else, checking, depth, env, frame, result) { return false; }
            } else {
                var flag = false;
                if field.len > 0 && field[0] == '@' {
                    if !tpl_loop_flag(tpl_trim(field[1..]), frame, flag, result) { return false; }
                } else if !tpl_flag(data, field, flag, result) {
                    return false;
                }
                let show = if kind == '#' { flag } else { !flag };
                if checking || show {
                    if !tpl_block(out, body, data, checking, depth + 1, env, frame, result) { return false; }
                }
            }
            pos = block_end;
            continue;
        }
        if !tpl_field(out, data, tag, true, result) { return false; }
    }
    return true;
}

// Runs a render with env. On false, out is left as it was and result.error says why.
fn render_env_result<T>(out: u8[>..]&, template: const u8[:], data: T&, env: TplEnv&) -> bool, TemplateResult {
    var result = TemplateResult { .. };
    if !valid_utf8(template) {
        tpl_fail(result, "template is not valid UTF-8");
        return false, result;
    }
    let start = out.len;
    if !tpl_block(out, template, data, false, 0, env, LoopFrame { .. }, result) {
        out.pop_n(out.len - start);
        return false, result;
    }
    result.ok = true;
    return true, result;
}

// Renders into out. On false, out is left as it was and result.error says why.
fn render_result<T>(out: u8[>..]&, template: const u8[:], data: T&) -> bool, TemplateResult {
    var none = templates();
    var blocks = PageBlocks { .. };
    var env = TplEnv { partials: none, blocks: blocks, mode: TPL_PLAIN, content: "", active_count: 0, .. };
    return render_env_result<T>(out, template, data, env);
}

// As render_result, with the partials of a registry available to {{> name}}.
fn render_result<T>(out: u8[>..]&, template: const u8[:], data: T&, partials: Templates&) -> bool, TemplateResult {
    var blocks = PageBlocks { .. };
    var env = TplEnv { partials: partials, blocks: blocks, mode: TPL_PLAIN, content: "", active_count: 0, .. };
    return render_env_result<T>(out, template, data, env);
}

// Renders the template into out. False on an unknown field, a malformed template, or output
// past TEMPLATE_MAX_OUTPUT_BYTES; out is then unchanged. Use render_result for the reason.
fn render<T>(out: u8[>..]&, template: const u8[:], data: T&) -> bool {
    let ok, result = render_result<T>(out, template, data);
    return ok;
}

fn render<T>(out: u8[>..]&, template: const u8[:], data: T&, partials: Templates&) -> bool {
    let ok, result = render_result<T>(out, template, data, partials);
    return ok;
}

// Renders a page into a layout: the page body (everything outside its blocks) goes where the
// layout has {{> content}}, the page's blocks fill the layout's {{$name}} slots, and the layout's
// own partials come from partials. out is unchanged on failure.
fn render_layout_result<T>(out: u8[>..]&, layout: const u8[:], page: const u8[:], data: T&, partials: Templates&) -> bool, TemplateResult {
    var result = TemplateResult { .. };
    if !valid_utf8(layout) || !valid_utf8(page) {
        tpl_fail(result, "template is not valid UTF-8");
        return false, result;
    }
    var blocks = PageBlocks { .. };
    if !collect_blocks(page, blocks, result) { return false, result; }
    var body: u8[>..] = [];
    var page_env = TplEnv { partials: partials, blocks: blocks, mode: TPL_PAGE, content: "", active_count: 0, .. };
    if !tpl_block(body, page, data, false, 0, page_env, LoopFrame { .. }, result) { return false, result; }
    var layout_env = TplEnv { partials: partials, blocks: blocks, mode: TPL_LAYOUT, content: body[..], active_count: 0, .. };
    let start = out.len;
    if !tpl_block(out, layout, data, false, 0, layout_env, LoopFrame { .. }, result) {
        out.pop_n(out.len - start);
        return false, result;
    }
    result.ok = true;
    return true, result;
}

fn render_layout<T>(out: u8[>..]&, layout: const u8[:], page: const u8[:], data: T&, partials: Templates&) -> bool {
    let ok, result = render_layout_result<T>(out, layout, page, data, partials);
    return ok;
}

// Startup check: validates every tag and section of the template against T, including the
// bodies of each blocks, without a real value. Returns true with an empty message, or false
// with the reason. Apps call it in main so template mistakes fail before the server starts.
fn check_template<T>(template: const u8[:]) -> bool, u8[>..] {
    var none = templates();
    return check_template<T>(template, none);
}

// Checks a template with the partials of a registry. Each partial is checked where the template
// uses it, with the data in scope there (so a row partial is checked against the row inside each);
// a partial no template uses is not checked, and a partial that includes itself is refused.
fn check_template<T>(template: const u8[:], partials: Templates&) -> bool, u8[>..] {
    var message: u8[>..] = [];
    if !valid_utf8(template) {
        message.append("template is not valid UTF-8");
        return false, message;
    }
    var out: u8[>..] = [];
    var data: T = T { .. };
    var result = TemplateResult { .. };
    var blocks = PageBlocks { .. };
    var env = TplEnv { partials: partials, blocks: blocks, mode: TPL_PLAIN, content: "", active_count: 0, .. };
    if !tpl_block(out, template, data, true, 0, env, LoopFrame { .. }, result) {
        message.append(result.error[..]);
        return false, message;
    }
    return true, message;
}

// Checks a page and its layout together, with the partials they use (each where it is used).
// The page's blocks are collected first, so a duplicate block is reported here.
fn check_template<T>(layout: const u8[:], page: const u8[:], partials: Templates&) -> bool, u8[>..] {
    var message: u8[>..] = [];
    if !valid_utf8(layout) || !valid_utf8(page) {
        message.append("template is not valid UTF-8");
        return false, message;
    }
    var result = TemplateResult { .. };
    var blocks = PageBlocks { .. };
    if !collect_blocks(page, blocks, result) {
        message.append(result.error[..]);
        return false, message;
    }
    var data: T = T { .. };
    var out: u8[>..] = [];
    var page_env = TplEnv { partials: partials, blocks: blocks, mode: TPL_PAGE, content: "", active_count: 0, .. };
    if !tpl_block(out, page, data, true, 0, page_env, LoopFrame { .. }, result) {
        message.append("page: ");
        message.append(result.error[..]);
        return false, message;
    }
    out.resize(0);
    var layout_env = TplEnv { partials: partials, blocks: blocks, mode: TPL_LAYOUT, content: "", active_count: 0, .. };
    if !tpl_block(out, layout, data, true, 0, layout_env, LoopFrame { .. }, result) {
        message.append("layout: ");
        message.append(result.error[..]);
        return false, message;
    }
    return true, message;
}

// --- responses --------------------------------------------------------------------------

// Writes the 500 template_error envelope for a failed render.
fn template_failed(c: Ctx&, result: TemplateResult&) {
    if valid_utf8(result.error[..]) {
        fail(c, HTTP_INTERNAL_SERVER_ERROR, "template_error", result.error[..]);
    } else {
        fail(c, HTTP_INTERNAL_SERVER_ERROR, "template_error", "template could not be rendered");
    }
}

// Renders the template and writes it as text/html. A render failure writes 500 template_error
// with the reason, so a broken template shows up in the response instead of a partial page.
fn html_template<T>(c: Ctx&, template: const u8[:], data: T) {
    var out: u8[>..] = [];
    let ok, result = render_result<T>(out, template, data);
    if !ok {
        template_failed(c, result);
        return;
    }
    write_body(c, CONTENT_TYPE_HTML, out[..]);
}

fn html_template<T>(c: Ctx&, partials: Templates&, template: const u8[:], data: T) {
    var out: u8[>..] = [];
    let ok, result = render_result<T>(out, template, data, partials);
    if !ok {
        template_failed(c, result);
        return;
    }
    write_body(c, CONTENT_TYPE_HTML, out[..]);
}

// Renders a page into a layout (see render_layout_result) and writes it as text/html.
fn html_page<T>(c: Ctx&, layout: const u8[:], page: const u8[:], data: T) {
    var none = templates();
    html_page<T>(c, none, layout, page, data);
}

fn html_page<T>(c: Ctx&, partials: Templates&, layout: const u8[:], page: const u8[:], data: T) {
    var out: u8[>..] = [];
    let ok, result = render_layout_result<T>(out, layout, page, data, partials);
    if !ok {
        template_failed(c, result);
        return;
    }
    write_body(c, CONTENT_TYPE_HTML, out[..]);
}
