import src.constants.limits;
import std;
namespace web;

// The shared store over native/posix/shared.c: one anonymous mapping made before the workers fork, so every
// worker process reads and writes the same table, SSE ring and stream registry. These are the raw calls;
// application code uses src/app/shared.goose, and the runtime uses the ring and registry directly.
// Return values follow the C side: 1 or 0 for success and full, -1 for refused, lengths for reads.

// Creates the store with bytes of memory (0 turns it off). Called by serve_config before any fork.
extern fn gw_shared_open(bytes: i64) -> i32;
extern fn gw_shared_enabled() -> i32;
extern fn gw_shared_set(key: const u8[:], value: const u8[:], ttl_ms: i64) -> i32;
extern fn gw_shared_get(key: const u8[:], out: u8[:]) -> i64;
extern fn gw_shared_delete(key: const u8[:]) -> i32;
extern fn gw_shared_incr(key: const u8[:], delta: i64, ttl_ms: i64, value: i64&, remaining_ms: i64&) -> i32;
// Event ring: publish a framed message, read the next one after a reader's position, start a reader.
extern fn gw_shared_ring_push(channel: i32, bytes: const u8[:]) -> i64;
extern fn gw_shared_ring_read(position: i64&, seq: i64&, channel: i32&, out: u8[:]) -> i64;
extern fn gw_shared_ring_head(position: i64&, seq: i64&);
extern fn gw_shared_lost() -> i64;
// Stream registry: which connection slots of which processes hold an event stream on a channel.
extern fn gw_shared_stream_add(slot: i32, channel: i32) -> i32;
extern fn gw_shared_stream_remove(slot: i32);
extern fn gw_shared_stream_count(channel: i32) -> i64;

// Whether the store exists in this process (serve_config created it, with a nonzero size).
fn shared_enabled() -> bool {
    return gw_shared_enabled() == 1;
}

// Creates or removes the store. Returns false when the size is refused or the mapping cannot be made.
fn shared_store_open(bytes: i64) -> bool {
    return gw_shared_open(bytes) == 0;
}
