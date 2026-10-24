import src.constants.limits;
import src.constants.runtime;
import src.sys.shared;
import std;
namespace web;

// Application API for the shared store: key/value entries and counters that every worker process of one
// server reads and writes. The store exists while the server runs (ServerConfig.shared_store_bytes, 1 MiB by
// default; 0 turns it off). Entries are bounded: keys up to SHARED_KEY_MAX_BYTES, values up to
// SHARED_VALUE_MAX_BYTES, and the table holds what fits in the store. A full table refuses a new key; it never
// evicts a live entry. Expired entries give their room back when a new key needs it. See docs/api.md#shared-store.

fn shared_key_valid(key: const u8[:]) -> bool {
    return key.len >= 1 && key.len <= SHARED_KEY_MAX_BYTES;
}

fn shared_ttl_valid(ttl_ms: i64) -> bool {
    return ttl_ms >= 0 && ttl_ms <= SHARED_TTL_MAX_MS;
}

// Stores value under key, replacing any earlier value. ttl_ms of 0 keeps the entry until it is deleted or
// replaced; otherwise it expires ttl_ms milliseconds later. Returns false, storing nothing, when the store is
// off, the key or value is out of bounds, the time-to-live is out of range, or the table has no free slot.
fn shared_set(key: const u8[:], value: const u8[:], ttl_ms: i64 = 0) -> bool {
    if !shared_key_valid(key) || value.len > SHARED_VALUE_MAX_BYTES || !shared_ttl_valid(ttl_ms) { return false; }
    return gw_shared_set(key, value, ttl_ms) == 1;
}

// Copies the live value under key into out, replacing what it held. Returns false, with out empty, when the key
// is absent or expired or the store is off.
fn shared_get(key: const u8[:], out: u8[>..]&) -> bool {
    out.clear();
    if !shared_key_valid(key) { return false; }
    out.resize(SHARED_VALUE_MAX_BYTES, 0);
    let length = gw_shared_get(key, out[..]);
    if length < 0 || length > SHARED_VALUE_MAX_BYTES {
        out.clear();
        return false;
    }
    out.resize(length, 0);
    return true;
}

// Removes the live entry under key. True when one was removed.
fn shared_delete(key: const u8[:]) -> bool {
    if !shared_key_valid(key) { return false; }
    return gw_shared_delete(key) == 1;
}

// Counters of the store, for monitoring. capacity is the number of entry slots (all stripes), stripes is how
// many locks split them, timeouts counts lock waits that gave up (a timed-out call returns false, or the
// rate limit falls back to its per-process table), recoveries counts locks taken over from a dead worker,
// and ring_lost counts events overwritten before a stream read them. entries and ring_lost are -1 when their
// lock could not be had in time. All are 0 when the store is off.
struct SharedStats {
    entries: i64, capacity: i64, stripes: i64, timeouts: i64, recoveries: i64, ring_lost: i64
}

fn shared_stats() -> SharedStats {
    var entries: i64 = 0;
    var capacity: i64 = 0;
    var stripes: i64 = 0;
    var timeouts: i64 = 0;
    var recoveries: i64 = 0;
    var ring_lost: i64 = 0;
    gw_shared_stats(entries, capacity, stripes, timeouts, recoveries, ring_lost);
    return SharedStats { entries: entries, capacity: capacity, stripes: stripes, timeouts: timeouts,
        recoveries: recoveries, ring_lost: ring_lost };
}

// Adds delta to the counter under key and returns the new value and true. A missing or expired counter starts
// from 0 and takes ttl_ms (0: no expiry). An existing counter keeps its expiry, so ttl_ms opens a fixed window
// that later increments do not extend. Returns 0 and false when refused, when the table is full, or on overflow.
fn shared_incr(key: const u8[:], delta: i64, ttl_ms: i64) -> i64, bool {
    let value, _, ok = shared_incr_window(key, delta, ttl_ms);
    return value, ok;
}

// As shared_incr, and also the milliseconds left before the counter expires (0 when it never does).
fn shared_incr_window(key: const u8[:], delta: i64, ttl_ms: i64) -> i64, i64, bool {
    var value: i64 = 0;
    var remaining: i64 = 0;
    if !shared_key_valid(key) || !shared_ttl_valid(ttl_ms) { return 0, 0, false; }
    if gw_shared_incr(key, delta, ttl_ms, value, remaining) != 1 { return 0, 0, false; }
    return value, remaining, true;
}
