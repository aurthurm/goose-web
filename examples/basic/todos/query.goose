import goose_web;
import .store;
import std;
namespace todo;

// The list query is not JSON, so it keeps its own strict parser. The codec handles bodies.
const DEFAULT_PAGE_SIZE = 8;
const MAX_PAGE_SIZE = 8;
const FILTER_ALL = -1;
const FILTER_INCOMPLETE = 0;
const FILTER_COMPLETED = 1;
const MAX_QUERY_INTEGER = 9223372036854775807;

struct ListOptions { status: i32, limit: i64, offset: i64, completed: i32 }
// Documents the list query for OpenAPI only: parse_list_query does the parsing. An omitted
// completed key means all todos, which the schema cannot express beyond true or false.
struct TodoListParams { limit: i64 = DEFAULT_PAGE_SIZE, offset: i64 = 0, completed: bool = false }

fn passes_filter(item: Todo, filter: i32) -> bool {
    return filter == FILTER_ALL || (filter == FILTER_COMPLETED && item.completed) || (filter == FILTER_INCOMPLETE && !item.completed);
}

// Decimal arithmetic is bounded before multiplying, including the last digit
// of the largest signed 64-bit integer.
fn parse_nonnegative(text: const u8[:]) -> i64, bool {
    if text.len == 0 { return 0, false; }
    var value: i64 = 0;
    for c in text {
        if c < '0' || c > '9' { return 0, false; }
        let digit: i64 = c - '0';
        if value > (MAX_QUERY_INTEGER - digit) / 10 { return 0, false; }
        value = value * 10 + digit;
    }
    return value, true;
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
