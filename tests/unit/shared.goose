// The shared store API: entries, expiry, counters, bounds, a full table, the disabled store, and the
// server configuration that sizes it. Single process; the cross-process behavior is in tests/native/shared.c
// and tests/integration/workers.py.
import goose_web from "../..";
import std;

// Busy-waits for at least ms milliseconds on the monotonic clock. The store expires on that clock too.
fn wait_ms(ms: i64) {
    let start = web::clock_ns();
    while web::clock_ns() - start < ms * web::NANOSECONDS_PER_MILLISECOND {}
}

// Without a store every call refuses, and nothing is read back.
fn test_disabled_store() {
    assert(web::shared_store_open(0));
    assert(!web::shared_enabled());
    assert(!web::shared_set("k", "v"));
    var out: u8[>..] = [];
    assert(!web::shared_get("k", out));
    assert(out.len == 0);
    assert(!web::shared_delete("k"));
    let value, ok = web::shared_incr("n", 1, 0);
    assert(!ok && value == 0);
}

// Entries round-trip, replace, delete, and refuse out-of-bound keys, values and ttls.
fn test_entries() {
    assert(web::shared_store_open(web::DEFAULT_SHARED_STORE_BYTES));
    assert(web::shared_enabled());
    assert(web::shared_set("alpha", "one"));
    var out: u8[>..] = [];
    assert(web::shared_get("alpha", out));
    assert(out[..] == "one");
    assert(web::shared_set("alpha", "uno"));
    assert(web::shared_get("alpha", out) && out[..] == "uno");
    assert(web::shared_delete("alpha"));
    assert(!web::shared_delete("alpha"));
    assert(!web::shared_get("alpha", out) && out.len == 0);

    assert(!web::shared_set("", "x"));
    var long_key: u8[>..] = [];
    long_key.resize(web::SHARED_KEY_MAX_BYTES + 1, 'k');
    assert(!web::shared_set(long_key[..], "x"));
    assert(!web::shared_get(long_key[..], out));
    var big: u8[>..] = [];
    big.resize(web::SHARED_VALUE_MAX_BYTES + 1, 'v');
    assert(!web::shared_set("big", big[..]));
    big.resize(web::SHARED_VALUE_MAX_BYTES, 'v');
    assert(web::shared_set("big", big[..]));
    assert(web::shared_get("big", out) && out.len == web::SHARED_VALUE_MAX_BYTES);
    assert(!web::shared_set("ttl", "x", web::SHARED_TTL_MAX_MS + 1));
    assert(!web::shared_set("ttl", "x", -1));
}

// A ttl makes an entry vanish once it passes; zero keeps it.
fn test_expiry() {
    assert(web::shared_set("short", "x", 30));
    assert(web::shared_set("long", "y", 0));
    wait_ms(60);
    var out: u8[>..] = [];
    assert(!web::shared_get("short", out));
    assert(web::shared_get("long", out) && out[..] == "y");
}

// Counters add and report the value; a window keeps its expiry until it lapses.
fn test_counters() {
    let value, ok = web::shared_incr("count", 5, 0);
    assert(ok && value == 5);
    let again, again_ok = web::shared_incr("count", -2, 0);
    assert(again_ok && again == 3);
    let window, left, window_ok = web::shared_incr_window("window", 1, 60000);
    assert(window_ok && window == 1 && left > 0 && left <= 60000);
    let second, second_left, second_ok = web::shared_incr_window("window", 1, 99999999);
    assert(second_ok && second == 2 && second_left > 0 && second_left <= 60000);
    assert(web::shared_set("text", "abc"));
    let unused, text_ok = web::shared_incr("text", 1, 0);
    assert(!text_ok && unused == 0);
    let big, big_ok = web::shared_incr("counter-max", 9223372036854775807, 0);
    assert(big_ok && big == 9223372036854775807);
    let overflow, overflow_ok = web::shared_incr("counter-max", 1, 0);
    assert(!overflow_ok && overflow == 0);
}

// A counter whose window lapsed starts again from zero.
fn test_window_restarts() {
    let first, _, first_ok = web::shared_incr_window("lapse", 1, 30);
    assert(first_ok && first == 1);
    wait_ms(60);
    let restarted, _, restarted_ok = web::shared_incr_window("lapse", 1, 30);
    assert(restarted_ok && restarted == 1);
}

// The table is bounded: a new key is refused when no slot is free, deleting frees one, and expired entries
// free theirs for new keys.
fn test_full_table() {
    var key: u8[>..] = [];
    var stored: i64 = 0;
    loop {
        key.clear();
        format(key, "fill-", stored);
        if !web::shared_set(key[..], "payload") { break; }
        stored += 1;
    }
    assert(stored > 0);
    assert(!web::shared_set("one-more", "x"));
    key.clear();
    format(key, "fill-", 0);
    assert(web::shared_delete(key[..]));
    assert(web::shared_set("one-more", "x"));
    assert(web::shared_delete("one-more"));
    var shorts: i64 = 0;
    loop {
        key.clear();
        format(key, "short-", shorts);
        if !web::shared_set(key[..], "payload", 30) { break; }
        shorts += 1;
    }
    assert(shorts > 0);
    assert(!web::shared_set("late", "x"));
    wait_ms(60);
    assert(web::shared_set("late", "x"));
    assert(web::shared_store_open(0));
}

// The store size is validated with the rest of the server configuration: zero is off, and the range is
// MIN_SHARED_STORE_BYTES to MAX_SHARED_STORE_BYTES.
fn test_config_sizes() {
    var config = web::server_config();
    assert(config.shared_store_bytes == web::DEFAULT_SHARED_STORE_BYTES);
    assert(web::validate_server_config(config));
    config.shared_store_bytes = 0;
    assert(web::validate_server_config(config));
    config.shared_store_bytes = web::MIN_SHARED_STORE_BYTES;
    assert(web::validate_server_config(config));
    config.shared_store_bytes = web::MIN_SHARED_STORE_BYTES - 1;
    assert(!web::validate_server_config(config));
    config.shared_store_bytes = web::MAX_SHARED_STORE_BYTES + 1;
    assert(!web::validate_server_config(config));
}

fn main() {
    test_disabled_store();
    test_entries();
    test_expiry();
    test_counters();
    test_window_restarts();
    test_full_table();
    test_config_sizes();
    print("shared store unit tests passed");
}
