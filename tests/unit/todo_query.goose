import goose_web from "../..";
import todo_app from "../../examples/basic/todos";
import std;

fn test_numbers() {
    for text in ["0", "1", "12", "9223372036854775807"] {
        let value, ok = todo::parse_nonnegative(text);
        assert(ok && value >= 0);
    }
    let largest, valid = todo::parse_nonnegative("9223372036854775807");
    assert(valid && largest == todo::MAX_QUERY_INTEGER);
    for text in ["", "+1", "-1", " 1", "1 ", "1.0", "1e2", "1/2", "1%32", "\xff",
                 "9223372036854775808", "9999999999999999999999999999"] {
        let value, ok = todo::parse_nonnegative(text);
        assert(!ok);
    }
}

fn test_list_query() {
    let defaults = todo::parse_list_query("/todos");
    assert(defaults.status == web::HTTP_OK && defaults.limit == todo::DEFAULT_PAGE_SIZE && defaults.offset == 0 && defaults.completed == todo::FILTER_ALL);
    assert(todo::parse_list_query("/todos?").status == web::HTTP_OK);
    let valid = todo::parse_list_query("/todos?limit=3&offset=2&completed=true");
    assert(valid.status == web::HTTP_OK && valid.limit == 3 && valid.offset == 2 && valid.completed == todo::FILTER_COMPLETED);
    let encoded = todo::parse_list_query("/todos?%6cimit=%38&off%73et=000&completed=f%61lse");
    assert(encoded.status == web::HTTP_OK && encoded.limit == 8 && encoded.offset == 0 && encoded.completed == todo::FILTER_INCOMPLETE);
    assert(todo::parse_list_query("/todos?offset=9223372036854775807").status == web::HTTP_OK);
    for target in ["/todos?limit=0", "/todos?limit=9", "/todos?limit=-1", "/todos?limit=+1", "/todos?limit=1.0", "/todos?limit",
                   "/todos?offset=-1", "/todos?offset=9223372036854775808", "/todos?completed=1", "/todos?completed=True", "/todos?completed=",
                   "/todos?unknown=1", "/todos?limit=1&limit=2", "/todos?limit=1&%6cimit=2", "/todos?offset=0&%6fffset=1",
                   "/todos?completed=true&complet%65d=false", "/todos?limit=1&", "/todos?&limit=1", "/todos?limit=1&&offset=0"] {
        assert(todo::parse_list_query(target).status == web::HTTP_UNPROCESSABLE_CONTENT);
    }
    for target in ["/todos?limit=%", "/todos?%GG=1", "/todos?offset=%0", "/todos?unknown=1&completed=%GG"] {
        assert(todo::parse_list_query(target).status == web::HTTP_BAD_REQUEST);
    }
    let long: u8[web::MAX_QUERY_FIELD_BYTES + 1] = ['x'; web::MAX_QUERY_FIELD_BYTES + 1];
    var target: u8[>..] = [];
    format(target, "/todos?completed=", long);
    assert(todo::parse_list_query(target).status == web::HTTP_CONTENT_TOO_LARGE);
    target.clear();
    format(target, "/todos?", long, "=x");
    assert(todo::parse_list_query(target).status == web::HTTP_CONTENT_TOO_LARGE);
}

fn main() {
    test_numbers();
    test_list_query();
    print("Todo query tests passed: pagination bounds, filters, duplicate and unknown keys, percent-decoding, field limits");
}
