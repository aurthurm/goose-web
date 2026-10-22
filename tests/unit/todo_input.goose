import goose_web from "../..";
import todo_app from "../../examples/basic/todos";
import std;

fn expect_input(body: const u8[:], mode: i32, status: i32) {
    assert(todo::read_input(body, mode).status == status);
}
fn test_payloads() {
    let created = todo::read_input("{\"title\":\"Buy milk\"}", todo::INPUT_CREATE);
    assert(created.status == web::HTTP_OK && created.title == "Buy milk" && !created.completed);
    assert(created.has_title && !created.has_completed);
    let escaped = todo::read_input("{\"ti\\u0074le\":\"caf\\u00e9 \\ud83d\\udc25\",\"completed\":true}", todo::INPUT_REPLACE);
    assert(escaped.status == web::HTTP_OK && escaped.title == "caf\xc3\xa9 \xf0\x9f\x90\xa5" && escaped.completed);
    let patched = todo::read_input("{\"completed\":false}", todo::INPUT_PATCH);
    assert(patched.status == web::HTTP_OK && !patched.has_title && patched.has_completed && !patched.completed);
    expect_input("{\"title\":\"new\"}", todo::INPUT_PATCH, web::HTTP_OK);
    for body in ["", "{", "{\"title\":\"a\",}", "{\"title\":\"\\x\"}", "{\"title\":\"unterminated}", "{\"title\":\"a\"} false",
                 "{\"title\":\"raw\nnewline\"}", "{\"title\":NaN}", "{\"title\":\"a\xff\"}", "{\"\xff\":true}",
                 "{\"title\":\"a\\ud800\"}", "{\"title\":\"a\",\"\\udc00\":true}"] { expect_input(body, todo::INPUT_CREATE, web::HTTP_BAD_REQUEST); }
    for body in ["null", "[]", "false", "42", "\"title\"", "{}", "{\"completed\":true}", "{\"title\":null}",
                 "{\"title\":123}", "{\"title\":false}", "{\"title\":[]}", "{\"title\":{}}", "{\"title\":\"\"}",
                 "{\"title\":\"   \"}", "{\"title\":\"\\u00a0\\u2003\"}", "{\"title\":\"a\",\"completed\":0}", "{\"title\":\"a\",\"completed\":\"false\"}",
                 "{\"title\":\"a\",\"completed\":null}", "{\"title\":\"a\",\"unknown\":1}", "{\"Title\":\"a\"}",
                 "{\"title\":\"a\",\"title\":\"b\"}", "{\"title\":\"a\",\"ti\\u0074le\":\"b\"}",
                 "{\"title\":\"a\",\"completed\":true,\"complet\\u0065d\":false}", "{\"title\":\"a\\n\"}",
                 "{\"title\":\"a\\u0000\"}", "{\"title\":\"a\\u007f\"}"] {
        expect_input(body, todo::INPUT_CREATE, web::HTTP_UNPROCESSABLE_CONTENT);
    }
    expect_input("{\"title\":\"a\"}", todo::INPUT_REPLACE, web::HTTP_UNPROCESSABLE_CONTENT);
    expect_input("{\"completed\":true}", todo::INPUT_REPLACE, web::HTTP_UNPROCESSABLE_CONTENT);
    expect_input("{}", todo::INPUT_PATCH, web::HTTP_UNPROCESSABLE_CONTENT);
    expect_input("{\"title\":\"a\"}", 99, web::HTTP_UNPROCESSABLE_CONTENT);
    let title: u8[todo::MAX_TITLE_BYTES + 1] = ['x'; todo::MAX_TITLE_BYTES + 1];
    var body: u8[>..] = [];
    format(body, "{\"title\":\"", title[..todo::MAX_TITLE_BYTES], "\"}");
    expect_input(body, todo::INPUT_CREATE, web::HTTP_OK);
    body.clear();
    format(body, "{\"title\":\"", title, "\"}");
    expect_input(body, todo::INPUT_CREATE, web::HTTP_UNPROCESSABLE_CONTENT);
    var borrowed: u8[..128] = "{\"title\":\"owned\\u0020title\"}";
    let owned = todo::read_input(borrowed, todo::INPUT_CREATE);
    borrowed = "destroyed";
    assert(owned.status == web::HTTP_OK && owned.title == "owned title");
}

fn test_ids() {
    for text in ["1", "12", "9223372036854775807"] {
        let value, ok = todo::parse_id(text);
        assert(ok && value > 0);
    }
    let largest, valid = todo::parse_id("9223372036854775807");
    assert(valid && largest == todo::MAX_INPUT_INTEGER);
    for text in ["", "0", "00", "01", "+1", "-1", " 1", "1 ", "1.0", "1e2", "1/2", "1%32", "\xff",
                 "9223372036854775808", "9999999999999999999999999999"] {
        let value, ok = todo::parse_id(text);
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
    test_payloads();
    test_ids();
    test_list_query();
    print("Todo input tests passed: JSON modes, decoded duplicate keys, owned strings, IDs, strict query validation");
}
