import .store;
import json;
import std;
namespace todo;

const INPUT_CREATE = 1;
const INPUT_REPLACE = 2;
const INPUT_PATCH = 3;
const DEFAULT_PAGE_SIZE = 8;
const MAX_PAGE_SIZE = 8;
const FILTER_ALL = -1;
const FILTER_INCOMPLETE = 0;
const FILTER_COMPLETED = 1;
const MAX_INPUT_INTEGER = 9223372036854775807;

struct TodoInput {
    title: u8[..MAX_TITLE_BYTES], completed: bool,
    has_title: bool, has_completed: bool, status: i32
}
struct ListOptions { status: i32, limit: i64, offset: i64, completed: i32 }

// Parse the whole document first. DOM keys are decoded, so escaped equivalents
// participate in duplicate detection just like ordinary keys. The returned
// value owns every byte needed after the document buffers go out of scope.
fn read_input(body: const u8[:], mode: i32) -> TodoInput {
    var result = default<TodoInput>();
    result.status = web::HTTP_BAD_REQUEST;
    if !web::valid_utf8(body) { return result; }
    var nodes: json::Node[>..] = [];
    var decoded: u8[>..] = [];
    let root, error = json::parse(body, nodes, decoded);
    if !root { return result; }
    // The JSON library preserves lone surrogate escapes as invalid UTF-8.
    // Validate every decoded key/string before applying the Todo schema.
    for &node in nodes {
        if !web::valid_utf8(node.key) { return result; }
        match node.val {
            Str text => { if !web::valid_utf8(text.s) { return result; } },
            _ => {}
        }
    }
    result.status = web::HTTP_UNPROCESSABLE_CONTENT;
    match root.val { Obj => {}, _ => { return result; } }
    if mode != INPUT_CREATE && mode != INPUT_REPLACE && mode != INPUT_PATCH { return result; }
    var child = root.first;
    while child {
        if child.key == "title" {
            if result.has_title { return result; }
            let title, valid_type = json::as_string(child);
            if !valid_type || !title_valid(title) { return result; }
            result.title = title;
            result.has_title = true;
        } else if child.key == "completed" {
            if result.has_completed { return result; }
            let completed, valid_type = json::as_bool(child);
            if !valid_type { return result; }
            result.completed = completed;
            result.has_completed = true;
        } else { return result; }
        child .= child.next;
    }
    if mode == INPUT_CREATE && !result.has_title { return result; }
    if mode == INPUT_REPLACE && (!result.has_title || !result.has_completed) { return result; }
    if mode == INPUT_PATCH && !result.has_title && !result.has_completed { return result; }
    result.status = web::HTTP_OK;
    return result;
}

// Decimal arithmetic is bounded before multiplying, including the last digit
// of the largest signed 64-bit integer. Query numbers may have leading zeros.
fn parse_nonnegative(text: const u8[:]) -> i64, bool {
    if text.len == 0 { return 0, false; }
    var value: i64 = 0;
    for c in text {
        if c < '0' || c > '9' { return 0, false; }
        let digit: i64 = c - '0';
        if value > (MAX_INPUT_INTEGER - digit) / 10 { return 0, false; }
        value = value * 10 + digit;
    }
    return value, true;
}
fn parse_id(text: const u8[:]) -> i64, bool {
    if text.len == 0 || text[0] == '0' { return 0, false; }
    let value, valid = parse_nonnegative(text);
    return value, valid && value > 0;
}

// Decode each pair once and retain explicit presence flags. Percent-encoded
// keys therefore cannot bypass duplicate checks. Scan all pairs even after a
// schema failure so a later malformed/oversized field is still reported.
fn parse_list_query(target: const u8[:]) -> ListOptions {
    var result = ListOptions { status: web::HTTP_OK, limit: DEFAULT_PAGE_SIZE, offset: 0, completed: FILTER_ALL };
    var have_limit = false;
    var have_offset = false;
    var have_completed = false;
    let query = web::target_query(target);
    if query.len == 0 { return result; }
    var pos: i64 = 0;
    loop {
        let amp = ::find(query[pos..], "&");
        let end = if amp < 0 { query.len } else { pos + amp };
        let pair = query[pos..end];
        let equals = ::find(pair, "=");
        let name = web::query_decode(if equals < 0 { pair } else { pair[..equals] });
        let value = web::query_decode(if equals < 0 { pair[pair.len..] } else { pair[equals + 1..] });
        if name.status != web::HTTP_OK { result.status = name.status; return result; }
        if value.status != web::HTTP_OK { result.status = value.status; return result; }
        if name.value == "limit" {
            let number, valid = parse_nonnegative(value.value);
            if have_limit || !valid || number < 1 || number > MAX_PAGE_SIZE { result.status = web::HTTP_UNPROCESSABLE_CONTENT; }
            else { result.limit = number; }
            have_limit = true;
        } else if name.value == "offset" {
            let number, valid = parse_nonnegative(value.value);
            if have_offset || !valid { result.status = web::HTTP_UNPROCESSABLE_CONTENT; }
            else { result.offset = number; }
            have_offset = true;
        } else if name.value == "completed" {
            if have_completed || (value.value != "true" && value.value != "false") { result.status = web::HTTP_UNPROCESSABLE_CONTENT; }
            else { result.completed = if value.value == "true" { FILTER_COMPLETED } else { FILTER_INCOMPLETE }; }
            have_completed = true;
        } else { result.status = web::HTTP_UNPROCESSABLE_CONTENT; }
        if end == query.len { return result; }
        pos = end + 1;
    }
}
