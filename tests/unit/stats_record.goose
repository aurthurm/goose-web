// Import only the public package, just as an application does.
import goose_web from "../..";
import std;

// Every field gets its own value, negative ones included, so a dropped, swapped or truncated word shows.
fn sample_stats() -> web::ServerStats {
    var stats = default<web::ServerStats>();
    var k: i64 = 1;
    const for <N, A> in fields<web::ServerStats> {
        stats.A = if k % 2 == 0 { -k * 1234567890123 } else { k * 9876543210987 };
        k += 1;
    }
    return stats;
}

fn same_stats(a: web::ServerStats, b: web::ServerStats) -> bool {
    var equal = true;
    const for <N, A> in fields<web::ServerStats> {
        if a.A != b.A { equal = false; }
    }
    return equal;
}

// Encoding then decoding returns every field, and the frame has the documented layout.
fn test_round_trip_every_field() {
    let stats = sample_stats();
    var frame: u8[web::STATS_RECORD_BYTES] = [0; web::STATS_RECORD_BYTES];
    assert(web::encode_stats(stats, frame[..]));
    var decoded = default<web::ServerStats>();
    assert(web::decode_stats(frame[..], decoded));
    assert(same_stats(stats, decoded));

    // Magic (little-endian: low byte 0x31 first), then the field count, then the words in order.
    let magic_low: i64 = frame[0];
    let magic_high: i64 = frame[7];
    assert(magic_low == 0x31 && magic_high == 0x47);
    let count: i64 = frame[8];
    assert(count == web::stats_field_count<web::ServerStats>());
    let first_low: i64 = frame[web::STATS_HEADER_BYTES];
    assert(first_low == stats.accepted & 0xff);
    let first_high: i64 = frame[web::STATS_HEADER_BYTES + 7];
    assert(first_high == (stats.accepted >> 56) & 0xff);
    let padding: i64 = frame[web::STATS_RECORD_BYTES - 1];
    assert(padding == 0);
}

// A frame whose field count is not this build's is rejected, and decoding leaves stats alone.
fn test_wrong_field_count_rejected() {
    let stats = sample_stats();
    var frame: u8[web::STATS_RECORD_BYTES] = [0; web::STATS_RECORD_BYTES];
    assert(web::encode_stats(stats, frame[..]));
    var target = default<web::ServerStats>();

    frame[8] = frame[8] + 1; // a record from a build with one more field
    assert(!web::decode_stats(frame[..], target));
    assert(same_stats(target, default<web::ServerStats>()));

    frame[8] = frame[8] - 2; // a record from a build with one fewer field
    assert(!web::decode_stats(frame[..], target));
    assert(same_stats(target, default<web::ServerStats>()));

    frame[8] = frame[8] + 1; // restored: accepted again
    assert(web::decode_stats(frame[..], target));
    assert(same_stats(target, stats));
}

// A wrong magic or a wrong length is rejected as well.
fn test_bad_frames_rejected() {
    let stats = sample_stats();
    var frame: u8[web::STATS_RECORD_BYTES] = [0; web::STATS_RECORD_BYTES];
    assert(web::encode_stats(stats, frame[..]));
    var target = default<web::ServerStats>();

    frame[0] = frame[0] ^ 0xff;
    assert(!web::decode_stats(frame[..], target));
    frame[0] = frame[0] ^ 0xff;
    assert(!web::decode_stats(frame[..(web::STATS_RECORD_BYTES - 8)], target));
    assert(same_stats(target, default<web::ServerStats>()));
}

// Summing adds every field, so no field is left out of the totals.
fn test_add_stats_sums_every_field() {
    let a = sample_stats();
    var b = default<web::ServerStats>();
    b.accepted = 5;
    b.sse_dropped = 7;
    var total = default<web::ServerStats>();
    web::add_stats(total, a);
    web::add_stats(total, b);
    const for <N, A> in fields<web::ServerStats> {
        assert(total.A == a.A + b.A);
    }
}

// The frame has room for the struct, and the parent refuses a restart budget outside its range.
fn test_capacity_and_budget() {
    assert(web::stats_field_count<web::ServerStats>() <= web::STATS_FIELD_CAPACITY);
    assert(web::server_config().worker_restart_budget == web::WORKER_RESTART_BUDGET);
    var config = web::server_config();
    config.worker_restart_budget = web::WORKER_RESTART_BUDGET + 1;
    assert(!web::validate_server_config(config));
    config.worker_restart_budget = -1;
    assert(!web::validate_server_config(config));
}

fn main() {
    test_round_trip_every_field();
    test_wrong_field_count_rejected();
    test_bad_frames_rejected();
    test_add_stats_sums_every_field();
    test_capacity_and_budget();
    print("Stats record tests passed: every field round-trips, wrong field count and bad frames are rejected, sums cover every field");
}
