import goose_web;
import std;
import os;
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
// The persisted document. Its JSON shape is the codec's shape for this struct.
struct StoreFile { version: i64, next_id: i64, todos: Todo[..MAX_TODOS] }

// A Todo is a JSON object wherever it appears: in responses, lists and the store file.
fn web::json_put_value(out: u8[>..]&, v: todo::Todo&) -> bool { return web::json_put_fields(out, v); }
fn web::json_read_value(d: web::JsonDecoder&, out: todo::Todo&) { web::json_read_fields(d, out); }

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
// Reject control bytes, truncated, overlong and surrogate encodings, and codepoints > U+10FFFF.
// A title must also contain something other than Unicode whitespace.
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

// Writes the file in ascending ID order, so the bytes do not depend on slot reuse.
fn encode_store(out: u8[>..]&, state: Store&) {
    var list: Todo[..MAX_TODOS] = [];
    var previous: i64 = 0;
    loop {
        var selected: i64 = -1;
        var next = MAX_NEXT_ID;
        for i in state.slots.len {
            if state.slots[i].used && state.slots[i].item.id > previous && state.slots[i].item.id < next {
                next = state.slots[i].item.id; selected = i;
            }
        }
        if selected < 0 { break; }
        list.push(state.slots[selected].item);
        previous = next;
    }
    web::json_encode(out, StoreFile { version: STORE_VERSION, next_id: state.next_id, todos: list });
    out.push('\n');
}

// Strict decode through the codec (unknown, duplicate or mistyped keys fail), then the
// store's own invariants: a known version, IDs below next_id, unique IDs, valid titles.
fn decode_store(raw: const u8[:]) -> Store, bool {
    if raw.len > MAX_STORE_BYTES { return store(), false; }
    let file, result = web::json_decode<StoreFile>(raw);
    if !result.ok || file.version != STORE_VERSION || file.next_id < 1 || !web::has<StoreFile>(result, "todos") {
        return store(), false;
    }
    var state = store();
    state.next_id = file.next_id;
    for i in file.todos.len {
        let item = file.todos[i];
        if item.id < 1 || item.id >= file.next_id || !title_valid(item.title[..]) || find(state, item.id) >= 0 {
            return store(), false;
        }
        state.slots[i] = Slot { used: true, item: item };
    }
    return state, true;
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
