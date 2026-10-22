// Compile-time handler dispatch sample; proposed APIs remain experimental.
import std;
import events from "..";

fn main() {
    var q = event_queue();
    assert(emit(q, Event.Ready));
    assert(emit(q, Event.UserCreated { id: 42, tenant_id: 7 }));
    var handled: i64 = 0;
    let n = dispatch(q, 10) { ev =>
        match ev {
            Ready => { print("server ready"); handled++; },
            UserCreated u => { print("user id ", u.id, " tenant ", u.tenant_id); handled++; },
            _ => { handled++; }
        }
    };
    assert(n == 2);
    assert(handled == 2);
    assert(pending_events(q) == 0);
}
