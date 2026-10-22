import goose_web from "../..";
import todo_app from "../../examples/basic/todos";
import std;
import os;

fn bad(raw: const u8[:]) {
    var loaded, ok = todo::decode_store(raw);
    assert(!ok && todo::count(loaded) == 0 && loaded.next_id == 1);
}
fn main() {
    var owned = todo::store();
    var source_title: u8[>..] = []; source_title.append("Owned");
    let owned_item, owned_status = todo::create(owned, source_title, false);
    source_title[0] = 'X';
    assert(owned_status == 201 && owned_item.title == "Owned" && owned.slots[0].item.title == "Owned");
    var state = todo::store();
    assert(todo::count(state) == 0 && state.next_id == 1);
    let first, created = todo::create(state, "Buy \"milk\" \\ bread", false);
    assert(created == 201 && first.id == 1 && todo::count(state, 0) == 1);
    var wire: u8[>..] = [];
    todo::encode_item(wire, first);
    assert(find(wire, "\\\"milk\\\"") >= 0 && find(wire, "\\\\ bread") >= 0);
    let changed, updated = todo::update(state, first.id, "Done", true);
    assert(updated == 200 && changed.completed && todo::count(state, 1) == 1);
    let invalid, invalid_status = todo::update(state, first.id, "  ", false);
    assert(invalid_status == 422 && state.slots[todo::find(state, first.id)].item.title == "Done");
    let missing, missing_status = todo::update(state, 999, "title", false);
    assert(missing_status == 404);
    assert(todo::remove(state, 999) == 404 && todo::remove(state, first.id) == 204);
    let second, recreated = todo::create(state, "Second", false);
    assert(recreated == 201 && second.id == 2 && todo::find(state, 2) == 0);
    for i in todo::MAX_TODOS - 1 { let item, status = todo::create(state, "Task", false); assert(status == 201); }
    let overflow, full = todo::create(state, "Full", false);
    assert(full == 409 && todo::count(state) == todo::MAX_TODOS);
    var boundary: u8[128] = ['x'; 128];
    assert(todo::title_valid(boundary));
    var oversized: u8[129] = ['x'; 129];
    assert(!todo::title_valid(oversized) && !todo::title_valid("") && !todo::title_valid("   "));
    assert(!todo::title_valid("a\n") && !todo::title_valid("a\t") && !todo::title_valid("a\x7f"));
    assert(!todo::title_valid("\xc0\xaf") && !todo::title_valid("\xed\xa0\x80") &&
           !todo::title_valid("\xf4\x90\x80\x80") && !todo::title_valid("\xe2\x82"));
    assert(todo::title_valid("\xc3\xa9") && todo::title_valid("\xf0\x9f\x90\xa5"));
    assert(!todo::title_valid("\xc2\xa0") && !todo::title_valid("\xe3\x80\x80"));
    var exhausted = todo::store(); exhausted.next_id = todo::MAX_NEXT_ID - 1;
    let final_item, final_status = todo::create(exhausted, "Final ID", false);
    assert(final_status == 201 && final_item.id == todo::MAX_NEXT_ID - 1);
    assert(todo::remove(exhausted, final_item.id) == 204);
    let none, exhausted_status = todo::create(exhausted, "Task", false);
    assert(exhausted_status == 503 && exhausted.next_id == todo::MAX_NEXT_ID && todo::count(exhausted) == 0);
    var text: u8[>..] = [];
    todo::encode_store(text, state);
    var loaded, ok = todo::decode_store(text);
    assert(ok && loaded.next_id == state.next_id && todo::count(loaded) == todo::MAX_TODOS);
    assert(todo::remove(loaded, 2) == 204);
    let last, last_status = todo::create(loaded, "Last", true);
    assert(last_status == 201 && last.id == state.next_id);
    text.clear(); todo::encode_store(text, loaded);
    assert(find(text, "\"id\":3,") < find(text, "\"id\":130,"));
    var reread, valid = todo::decode_store(text);
    assert(valid && todo::find(reread, last.id) >= 0);
    bad("{"); bad("[]"); bad("{\"version\":2,\"next_id\":1,\"todos\":[]}");
    bad("{\"version\":1,\"next_id\":0,\"todos\":[]}");
    bad("{\"version\":1,\"next_id\":1.0,\"todos\":[]}");
    bad("{\"version\":1,\"version\":1,\"todos\":[]}");
    bad("{\"version\":1,\"next_id\":1,\"todos\":[{\"id\":1,\"title\":\"x\",\"completed\":false}]}");
    bad("{\"version\":1,\"next_id\":2,\"todos\":[{\"id\":1,\"title\":\"x\",\"completed\":false},{\"id\":1,\"title\":\"y\",\"completed\":true}]}");
    bad("{\"version\":1,\"next_id\":2,\"todos\":[{\"id\":1,\"title\":\" \",\"completed\":false}]}");
    bad("{\"version\":1,\"next_id\":2,\"todos\":[{\"id\":1,\"title\":\"\\uD800\",\"completed\":false}]}");
    var oversized_document: u8[>..] = [];
    format(oversized_document, "{\"version\":1,\"next_id\":130,\"todos\":[");
    for i in 129 {
        if i > 0 { oversized_document.push(','); }
        todo::encode_item(oversized_document, todo::Todo { id: i + 1, title: "Task", completed: false });
    }
    oversized_document.append("]}");
    bad(oversized_document);
    let argv = args();
    if argv.len > 1 {
        let path = argv[1];
        delete_file(path);
        var fresh, absent = todo::load(path);
        assert(absent && fresh.next_id == 1 && todo::count(fresh) == 0);
        assert(todo::save(loaded, path));
        var restored, saved_ok = todo::load(path);
        assert(saved_ok && restored.next_id == loaded.next_id && todo::count(restored) == todo::count(loaded));
        assert(write_file(path, "corrupt"));
        var corrupt, corrupt_ok = todo::load(path);
        assert(!corrupt_ok && todo::count(corrupt) == 0);
        assert(delete_file(path));
    }
    print("Todo store tests passed: owned mutations, limits, UTF8, IDs, JSON, atomic persistence");
}
