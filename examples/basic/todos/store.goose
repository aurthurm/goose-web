import goose_web;
import std;
import os;
import json;
namespace todo;

const MAX_TODOS = 128;
const MAX_TITLE_BYTES = 128;
const MAX_NEXT_ID = 9223372036854775807;
const STORE_VERSION = 1;
// A valid full store needs at most 6 escaped bytes per title byte plus metadata.
const MAX_STORE_BYTES = MAX_TODOS * (MAX_TITLE_BYTES * 6 + 128) + 128;

struct Todo { id: i64, title: u8[..MAX_TITLE_BYTES], completed: bool }
struct Slot { used: bool, item: Todo }
struct Store { slots: Slot[MAX_TODOS], next_id: i64 }

fn store() -> Store {
    return Store { slots: [default<Slot>(); MAX_TODOS], next_id: 1 };
}
fn find(state: Store&, id: i64) -> i64 {
    for i in state.slots.len { if state.slots[i].used && state.slots[i].item.id == id { return i; } }
    return -1;
}
fn count(state: Store&, completed_filter: i32 = -1) -> i64 {
    var total: i64 = 0;
    for slot in state.slots {
        if slot.used && (completed_filter == -1 ||
            (completed_filter == 1 && slot.item.completed) || (completed_filter == 0 && !slot.item.completed)) { total += 1; }
    }
    return total;
}

fn title_space(cp: i64) -> bool {
    return cp == 32 || cp == 0x85 || cp == 0xa0 || cp == 0x1680 ||
        (cp >= 0x2000 && cp <= 0x200a) || cp == 0x2028 || cp == 0x2029 || cp == 0x202f || cp == 0x205f || cp == 0x3000;
}
// Reject truncated, overlong and surrogate encodings, and codepoints > U+10FFFF.
fn title_valid(text: const u8[:]) -> bool {
    if text.len == 0 || text.len > MAX_TITLE_BYTES { return false; }
    var pos: i64 = 0;
    var nonblank = false;
    while pos < text.len {
        let lead = text[pos];
        var width: i64 = 1;
        var cp: i64 = lead;
        if lead < 32 || lead == 127 { return false; }
        if lead >= 0xc2 && lead <= 0xdf { width = 2; cp = lead & 0x1f; }
        else if lead >= 0xe0 && lead <= 0xef { width = 3; cp = lead & 0xf; }
        else if lead >= 0xf0 && lead <= 0xf4 { width = 4; cp = lead & 7; }
        else if lead >= 128 { return false; }
        if width > text.len - pos { return false; }
        for offset in 1..width {
            let c = text[pos + offset];
            if c < 0x80 || c > 0xbf { return false; }
            cp = cp * 64 + (c & 0x3f);
        }
        if (width == 2 && cp < 0x80) || (width == 3 && cp < 0x800) ||
           (width == 4 && cp < 0x10000) || (cp >= 0xd800 && cp <= 0xdfff) || cp > 0x10ffff { return false; }
        if !title_space(cp) { nonblank = true; }
        pos += width;
    }
    return nonblank;
}
fn create(state: Store&, title: const u8[:], completed: bool) -> Todo, i32 {
    if !title_valid(title) { return default<Todo>(), web::HTTP_UNPROCESSABLE_CONTENT; }
    if state.next_id <= 0 || state.next_id >= MAX_NEXT_ID { return default<Todo>(), web::HTTP_SERVICE_UNAVAILABLE; }
    for i in state.slots.len {
        if !state.slots[i].used {
            let item = Todo { id: state.next_id, title: title, completed: completed };
            state.slots[i] = Slot { used: true, item: item };
            state.next_id += 1;
            return item, web::HTTP_CREATED;
        }
    }
    return default<Todo>(), web::HTTP_CONFLICT;
}
fn update(state: Store&, id: i64, title: const u8[:], completed: bool) -> Todo, i32 {
    let index = find(state, id);
    if index < 0 { return default<Todo>(), web::HTTP_NOT_FOUND; }
    if !title_valid(title) { return default<Todo>(), web::HTTP_UNPROCESSABLE_CONTENT; }
    let item = Todo { id: id, title: title, completed: completed };
    state.slots[index].item = item;
    return item, web::HTTP_OK;
}
fn remove(state: Store&, id: i64) -> i32 {
    let index = find(state, id);
    if index < 0 { return web::HTTP_NOT_FOUND; }
    state.slots[index] = default<Slot>();
    return web::HTTP_NO_CONTENT;
}
fn encode_item(out: u8[>..]&, item: Todo) {
    format(out, "{\"id\":", item.id, ",\"title\":");
    json::format_string(out, item.title);
    out.append(",\"completed\":");
    json::format_bool(out, item.completed);
    out.push('}');
}
fn encode_store(out: u8[>..]&, state: Store&) {
    format(out, "{\"version\":", STORE_VERSION, ",\"next_id\":", state.next_id, ",\"todos\":[");
    var previous: i64 = 0;
    var first = true;
    loop {
        var selected: i64 = -1;
        var next = MAX_NEXT_ID;
        for i in state.slots.len {
            if state.slots[i].used && state.slots[i].item.id > previous && state.slots[i].item.id < next {
                next = state.slots[i].item.id; selected = i;
            }
        }
        if selected < 0 { break; }
        if !first { out.push(','); }
        encode_item(out, state.slots[selected].item);
        first = false;
        previous = next;
    }
    out.append("]}\n");
}
fn object_fields(node: json::Node?, expected: i64) -> bool {
    if !node { return false; }
    match node.val { Obj value => { return value.count == expected; }, _ => { return false; } }
}
fn decode_store(raw: const u8[:]) -> Store, bool {
    if raw.len > MAX_STORE_BYTES { return store(), false; }
    var nodes: json::Node[>..] = [];
    var decoded: u8[>..] = [];
    let root, error = json::parse(raw, nodes, decoded);
    if !object_fields(root, 3) { return store(), false; }
    let version, version_ok = json::as_i64(json::member(root, "version"));
    let next, next_ok = json::as_i64(json::member(root, "next_id"));
    let todos = json::member(root, "todos");
    if !version_ok || version != STORE_VERSION || !next_ok || next < 1 || !todos { return store(), false; }
    match todos.val { Arr value => { if value.count > MAX_TODOS { return store(), false; } }, _ => { return store(), false; } }
    var result = store();
    result.next_id = next;
    var entry = todos.first;
    var index: i64 = 0;
    while entry {
        if !object_fields(entry, 3) { return store(), false; }
        let id, id_ok = json::as_i64(json::member(entry, "id"));
        let title, title_ok = json::as_string(json::member(entry, "title"));
        let completed, completed_ok = json::as_bool(json::member(entry, "completed"));
        if !id_ok || id < 1 || id >= next || !title_ok || !title_valid(title) || !completed_ok ||
           find(result, id) >= 0 || index >= MAX_TODOS { return store(), false; }
        result.slots[index] = Slot { used: true, item: Todo { id: id, title: title, completed: completed } };
        index += 1;
        entry .= entry.next;
    }
    return result, true;
}
fn save(state: Store&, path: const u8[:]) -> bool {
    var text: u8[>..] = [];
    encode_store(text, state);
    return write_file_atomic(path, text);
}
fn load(path: const u8[:]) -> Store, bool {
    var text: u8[>..] = [];
    if !read_file(path, text) {
        if !file_exists(path) && !is_dir(path) { return store(), true; }
        return store(), false;
    }
    return decode_store(text);
}
