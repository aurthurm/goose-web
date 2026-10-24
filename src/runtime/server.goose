import src.constants.runtime;
import src.constants.http;
import src.constants.limits;
import src.http.request;
import src.http.response;
import src.http.errors;
import src.http.sse;
import std;
import src.sys.process;
import src.sys.shared;
namespace web;

extern fn gw_listen_config(port: i32, public_bind: i32) -> i32;
extern fn gw_transport_max_clients() -> i64;
extern fn gw_signals_begin() -> i32;
extern fn gw_signal_pending() -> i32;
extern fn gw_signals_end();

struct ServerConfig {
    port: i32, public_bind: bool, max_clients: i64, max_request_bytes: i64, max_response_bytes: i64,
    read_timeout_ms: i64, write_timeout_ms: i64, idle_timeout_ms: i64, poll_timeout_ms: i32,
    shutdown_grace_ms: i64, max_requests: i64, max_requests_per_connection: i64, keep_alive: bool,
    handle_signals: bool, max_pool_bytes: i64, max_sse_clients: i64, sse_heartbeat_ms: i64,
    sse_max_queued_bytes: i64, workers: i32, worker_restart_budget: i64, shared_store_bytes: i64,
    shared_lock_timeout_ms: i64
}
struct ServerStats {
    accepted: i64, active: i64, completed: i64, rejected: i64,
    timeouts: i64, forced_closes: i64, bytes_read: i64, bytes_written: i64, reused: i64,
    sse_active: i64, sse_sent: i64, sse_dropped: i64
}
// Load snapshot for load shedding (src/app/shedding.goose). record_pressure refreshes it before each handler runs.
// active: open connections; max_clients: the limit. pool_bytes_*: response bytes in flight and the pool's
// capacity. queued_events / max_queued_events: SSE messages staged in the outbox.
struct ServerPressure {
    active: i64, max_clients: i64, pool_bytes_used: i64, pool_bytes_max: i64,
    queued_events: i64, max_queued_events: i64
}
var live_pressure: ServerPressure = default<ServerPressure>();
// True in a worker process of serve_workers, so loggers can report its pid (src/app/logging.goose).
var worker_process: bool = false;
// One event stream slot, indexed like the connection slot it belongs to.
struct SseSlot { active: bool, channel: i32 }
// sse_limit, sse_slots and the message table are reactor state that sse_publish stages into. The
// message bytes live in sse_outbox, which the reactor drains at the start of each iteration. The
// struct stays fixed-size, so default<ServerControl>() works and costs no outbox memory.
struct ServerControl {
    shutdown_requested: bool, running: bool, stopping: bool, stats: ServerStats,
    // Monotonic time (clock_ns) of the next scheduled task, set by web::hint_wakeup; 0 means none.
    wake_at_ns: i64,
    sse_limit: i64, sse_slots: SseSlot[MAX_CLIENTS], sse_msg_count: i64,
    sse_msg_channel: i32[MAX_SSE_OUTBOX_MESSAGES], sse_msg_end: i64[MAX_SSE_OUTBOX_MESSAGES]
}
// Framed SSE bytes staged by sse_publish. It stays empty until the first publish, so an application
// that never streams allocates nothing for it. It is capped at MAX_SSE_OUTBOX_BYTES.
var sse_outbox: u8[>..] = [];
// With the shared store, each process reads the SSE ring from its own position. sse_stage holds one
// framed message between the ring and the outbox, and is allocated on first use only.
var sse_read_position: i64 = 0;
var sse_read_seq: i64 = 0;
var sse_stage: u8[>..] = [];
fn server_config() -> ServerConfig {
    return ServerConfig { port: DEFAULT_PORT, public_bind: DEFAULT_PUBLIC_BIND, max_clients: DEFAULT_MAX_CLIENTS,
        max_request_bytes: DEFAULT_MAX_REQUEST_BYTES, max_response_bytes: DEFAULT_MAX_RESPONSE_BYTES,
        read_timeout_ms: DEFAULT_READ_TIMEOUT_MS, write_timeout_ms: DEFAULT_WRITE_TIMEOUT_MS,
        idle_timeout_ms: DEFAULT_IDLE_TIMEOUT_MS, poll_timeout_ms: DEFAULT_POLL_TIMEOUT_MS,
        shutdown_grace_ms: DEFAULT_SHUTDOWN_GRACE_MS, max_requests: UNLIMITED_REQUESTS,
        max_requests_per_connection: DEFAULT_MAX_REQUESTS_PER_CONNECTION, keep_alive: DEFAULT_KEEP_ALIVE,
        handle_signals: DEFAULT_HANDLE_SIGNALS, max_pool_bytes: DEFAULT_MAX_POOL_BYTES,
        max_sse_clients: DEFAULT_MAX_SSE_CLIENTS, sse_heartbeat_ms: DEFAULT_SSE_HEARTBEAT_MS,
        sse_max_queued_bytes: DEFAULT_SSE_MAX_QUEUED_BYTES, workers: DEFAULT_WORKERS,
        worker_restart_budget: WORKER_RESTART_BUDGET, shared_store_bytes: DEFAULT_SHARED_STORE_BYTES,
        shared_lock_timeout_ms: DEFAULT_SHARED_LOCK_TIMEOUT_MS };
}
// Millisecond durations are capped at one day to keep nanosecond arithmetic safe.
// The pool must hold one maximal response, so a single response never needs more than the pool.
fn validate_server_config(c: ServerConfig) -> bool {
    return c.port >= MIN_PORT && c.port <= MAX_PORT && c.max_clients >= 1 && c.max_clients <= MAX_CLIENTS &&
        c.max_request_bytes >= 1 && c.max_request_bytes <= MAX_REQUEST_BYTES &&
        c.max_response_bytes >= 1 && c.max_response_bytes <= MAX_RESPONSE_BODY_BYTES &&
        c.max_pool_bytes >= c.max_response_bytes + MAX_RESPONSE_HEADER_BYTES && c.max_pool_bytes <= MAX_RESPONSE_POOL_BYTES &&
        c.max_requests >= UNLIMITED_REQUESTS &&
        c.max_requests_per_connection >= UNLIMITED_REQUESTS && c.max_requests_per_connection <= MAX_REQUESTS_PER_CONNECTION &&
        c.read_timeout_ms >= 1 && c.read_timeout_ms <= MAX_TIMEOUT_MS &&
        c.write_timeout_ms >= 1 && c.write_timeout_ms <= MAX_TIMEOUT_MS &&
        c.idle_timeout_ms >= 1 && c.idle_timeout_ms <= MAX_TIMEOUT_MS &&
        c.poll_timeout_ms >= 1 && c.poll_timeout_ms <= MAX_POLL_TIMEOUT_MS &&
        c.shutdown_grace_ms >= 0 && c.shutdown_grace_ms <= MAX_TIMEOUT_MS &&
        c.max_sse_clients >= 0 && c.max_sse_clients <= MAX_SSE_CLIENTS &&
        c.sse_heartbeat_ms >= 1 && c.sse_heartbeat_ms <= MAX_TIMEOUT_MS &&
        c.sse_max_queued_bytes >= MIN_SSE_QUEUED_BYTES && c.sse_max_queued_bytes <= MAX_SSE_QUEUED_BYTES &&
        c.workers >= 0 && c.workers <= MAX_WORKERS &&
        c.worker_restart_budget >= 0 && c.worker_restart_budget <= WORKER_RESTART_BUDGET &&
        (c.shared_store_bytes == 0 || (c.shared_store_bytes >= MIN_SHARED_STORE_BYTES && c.shared_store_bytes <= MAX_SHARED_STORE_BYTES)) &&
        c.shared_lock_timeout_ms >= MIN_SHARED_LOCK_TIMEOUT_MS && c.shared_lock_timeout_ms <= MAX_SHARED_LOCK_TIMEOUT_MS;
}
fn request_shutdown(control: ServerControl&) { control.shutdown_requested = true; }
extern fn gw_accept(listener: i32) -> i32;
extern fn gw_peer_address(fd: i32, out: u8[:]) -> i64;
extern fn gw_recv(fd: i32, buffer: u8[:]) -> i64;
extern fn gw_send(fd: i32, buffer: const u8[:]) -> i64;
extern fn gw_close(fd: i32);
// The reactor registers each descriptor once under a token; interest changes go through modify.
extern fn gw_reactor_open() -> i32;
extern fn gw_reactor_close();
extern fn gw_reactor_add(token: i32, fd: i32, write: i32) -> i32;
extern fn gw_reactor_modify(token: i32, fd: i32, write: i32) -> i32;
extern fn gw_reactor_remove(token: i32, fd: i32);
extern fn gw_reactor_wait(tokens: i32[:], ready: i32[:], timeout: i32) -> i32;

// Shared store for serialized responses in flight. A response is a linked list of
// chunks: pool.next[id] is the chunk after id, NO_CHUNK at the end. Freed chunks are
// reused, so memory tracks the peak of in-flight bytes, which never exceeds max_pool_bytes.
struct ChunkPool {
    count: i64, free_count: i64, max_chunks: i64, free: i64[MAX_POOL_CHUNKS], next: i64[MAX_POOL_CHUNKS],
    bytes: u8[>..]
}
// Unparsed request bytes. A connection borrows one block while it holds bytes and returns it when it
// goes idle or closes, so idle keep-alive connections hold no input memory. A block of class k holds
// input_class_bytes(k) bytes; a full block is replaced by one of the next class, copying its bytes.
// Blocks never move and are reused per class, so a Request view stays valid for its handler. The
// freed blocks of a class are at most MAX_CLIENTS, because each live block belongs to one connection.
struct InputPool {
    free_count: i64[INPUT_CLASSES], free: i64[INPUT_CLASSES * MAX_CLIENTS], max_bytes: i64,
    bytes: u8[>..]
}
// head is the first chunk not yet fully sent; head_start is the byte offset of head's first byte.
// A stream (sse) keeps its chain across events; sse_closing means the close event is queued.
// input_at and input_cap locate the connection's block in the InputPool (cap 0: no block).
struct Connection {
    fd: i32, used: i64, sent: i64, wire_len: i64, writing: bool, keep: bool, pipelined: bool,
    idle: bool, deadline: i64, served: i64, head: i64, head_start: i64,
    peer: u8[MAX_PEER_BYTES], peer_len: i64, sse: bool, sse_closing: bool, sse_channel: i32, slot: i64,
    watch_write: bool, input_at: i64, input_cap: i64, input_class: i64
}

// Copies the reactor's load into live_pressure. Called once per request, before the handler runs.
fn record_pressure(config: ServerConfig, control: ServerControl&, pool: ChunkPool&) {
    live_pressure = ServerPressure { active: control.stats.active, max_clients: config.max_clients,
        pool_bytes_used: (pool.count - pool.free_count) * RESPONSE_CHUNK_BYTES,
        pool_bytes_max: pool.max_chunks * RESPONSE_CHUNK_BYTES,
        queued_events: control.sse_msg_count, max_queued_events: MAX_SSE_OUTBOX_MESSAGES };
}

// Chunks that a new response could still take: freed ones plus never-used capacity.
fn pool_available(pool: ChunkPool&) -> i64 { return pool.free_count + pool.max_chunks - pool.count; }

// Caller checks pool_available first.
fn chunk_take(pool: ChunkPool&) -> i64 {
    if pool.free_count > 0 {
        pool.free_count -= 1;
        return pool.free[pool.free_count];
    }
    let id = pool.count;
    pool.count += 1;
    pool.bytes.resize(pool.count * RESPONSE_CHUNK_BYTES, 0);
    return id;
}

// Returns the chain starting at c.head to the pool. A connection with no staged
// response has wire_len 0 and no chain.
fn release_chunks(c: Connection&, pool: ChunkPool&) {
    if c.wire_len > 0 {
        while c.head != NO_CHUNK {
            let next = pool.next[c.head];
            pool.free[pool.free_count] = c.head;
            pool.free_count += 1;
            c.head = next;
        }
    }
    c.head = NO_CHUNK;
    c.head_start = 0;
    c.wire_len = 0;
    c.sent = 0;
}

// Capacity of a class-k input block: INPUT_MIN_BYTES doubled k times, never above the request limit.
fn input_class_bytes(k: i64, max_bytes: i64) -> i64 {
    var bytes: i64 = INPUT_MIN_BYTES;
    for j in k { bytes = bytes * 2; }
    return if bytes < max_bytes { bytes } else { max_bytes };
}

// Points c at a free class-k block, or at a new one at the end of the pool. c must hold no block.
fn input_attach(c: Connection&, inputs: InputPool&, k: i64) {
    let cap = input_class_bytes(k, inputs.max_bytes);
    var at: i64 = inputs.bytes.len;
    if inputs.free_count[k] > 0 {
        inputs.free_count[k] -= 1;
        at = inputs.free[k * MAX_CLIENTS + inputs.free_count[k]];
    } else {
        inputs.bytes.resize(at + cap, 0);
    }
    c.input_at = at;
    c.input_cap = cap;
    c.input_class = k;
}

fn input_free_block(inputs: InputPool&, k: i64, at: i64) {
    inputs.free[k * MAX_CLIENTS + inputs.free_count[k]] = at;
    inputs.free_count[k] += 1;
}

// Returns c's block to the pool. The caller guarantees that c holds no unparsed bytes.
fn input_detach(c: Connection&, inputs: InputPool&) {
    if c.input_cap == 0 { return; }
    input_free_block(inputs, c.input_class, c.input_at);
    c.input_at = 0;
    c.input_cap = 0;
}

// Gives c a block when it has none, and doubles a full block up to the request limit. Bytes are kept.
fn input_make_room(c: Connection&, inputs: InputPool&) {
    if c.input_cap == 0 {
        input_attach(c, inputs, 0);
        return;
    }
    if c.used < c.input_cap || c.input_cap >= inputs.max_bytes { return; }
    let old_at = c.input_at;
    let old_k = c.input_class;
    input_attach(c, inputs, old_k + 1);
    for i in c.used { inputs.bytes[c.input_at + i] = inputs.bytes[old_at + i]; }
    input_free_block(inputs, old_k, old_at);
}

// Closing a stream also frees its slot for a new stream. Streams are not keep-alive: a stream never
// returns to the request state, so its flags are cleared with the connection.
fn close_connection(c: Connection&, control: ServerControl&, pool: ChunkPool&, inputs: InputPool&) {
    if c.fd >= 0 { control.stats.active -= 1; }
    if c.sse {
        control.stats.sse_active -= 1;
        control.sse_slots[c.slot].active = false;
        gw_shared_stream_remove(c.slot as i32);
        c.sse = false;
        c.sse_closing = false;
    }
    // The reactor forgets the descriptor before it closes, so the number can be reused.
    gw_reactor_remove(c.slot as i32, c.fd);
    gw_close(c.fd);
    c.fd = INVALID_SOCKET;
    c.watch_write = false;
    release_chunks(c, pool);
    c.used = 0;
    input_detach(c, inputs);
    c.writing = false;
    c.keep = false;
    c.pipelined = false;
    c.idle = false;
    c.served = 0;
}

// Copies head then body into pool chunks and arms the write phase. The connection must hold no chain.
// Returns false, taking nothing, when the pool lacks chunks for the whole response.
fn stage_wire(c: Connection&, pool: ChunkPool&, head: const u8[:], body: const u8[:], timeout_ms: i64) -> bool {
    let total = head.len + body.len;
    if (total + RESPONSE_CHUNK_BYTES - 1) / RESPONSE_CHUNK_BYTES > pool_available(pool) { return false; }
    var pos: i64 = 0;
    var prev: i64 = NO_CHUNK;
    while pos < total {
        let id = chunk_take(pool);
        let n = if total - pos < RESPONSE_CHUNK_BYTES { total - pos } else { RESPONSE_CHUNK_BYTES };
        for i in n {
            let at = pos + i;
            pool.bytes[id * RESPONSE_CHUNK_BYTES + i] = if at < head.len { head[at] } else { body[at - head.len] };
        }
        pool.next[id] = NO_CHUNK;
        if prev == NO_CHUNK { c.head = id; } else { pool.next[prev] = id; }
        prev = id;
        pos += n;
    }
    c.head_start = 0;
    c.wire_len = total;
    c.sent = 0;
    c.writing = true;
    c.deadline = clock_ns() + timeout_ms * NANOSECONDS_PER_MILLISECOND;
    return true;
}

// Serializes r (head into head_buf, body straight from r) into pool chunks and arms the
// write phase. Returns false, taking nothing, when the pool lacks chunks for the whole response.
fn stage_response(c: Connection&, pool: ChunkPool&, head_buf: u8[>..]&, r: Response&, head: bool, close: bool, keep_alive: bool, timeout_ms: i64) -> bool {
    release_chunks(c, pool);
    head_buf.clear();
    prepare_response(r);
    serialize_head(head_buf, r, close, keep_alive);
    let body = if sends_body(r, head) { body_of(r) } else { "" };
    return stage_wire(c, pool, head_buf[..], body, timeout_ms);
}

// Stages the head of an event stream. There is no body; events are queued later.
fn stage_stream(c: Connection&, pool: ChunkPool&, head_buf: u8[>..]&, r: Response&, timeout_ms: i64) -> bool {
    release_chunks(c, pool);
    head_buf.clear();
    serialize_stream_head(head_buf, r);
    return stage_wire(c, pool, head_buf[..], "", timeout_ms);
}

// Drops the first `consumed` bytes of input. Bytes move forward, so overlap is safe.
fn consume_input(c: Connection&, inputs: InputPool&, consumed: i64) {
    for i in c.used - consumed { inputs.bytes[c.input_at + i] = inputs.bytes[c.input_at + consumed + i]; }
    c.used -= consumed;
}

// Keeps the kernel's interest in step with the connection: write while a response is queued, read
// otherwise. The kernel is called only when the interest changes. A failed update is retried next loop.
fn reactor_sync(c: Connection&) {
    if c.fd < 0 || c.watch_write == c.writing { return; }
    if gw_reactor_modify(c.slot as i32, c.fd, if c.writing { 1 } else { 0 }) == 0 { c.watch_write = c.writing; }
}

// Streams are limited by max_sse_clients, and no stream can exceed the connection slots.
fn sse_client_limit(config: ServerConfig) -> i64 {
    return if config.max_sse_clients < config.max_clients { config.max_sse_clients } else { config.max_clients };
}

// Appends bytes after the chain's last unsent byte. Each stream's unsent bytes count against limit.
// Returns false, changing nothing, when they would exceed limit or the pool lacks chunks.
fn sse_queue(c: Connection&, pool: ChunkPool&, bytes: const u8[:], limit: i64) -> bool {
    if c.wire_len - c.sent + bytes.len > limit { return false; }
    var used = c.wire_len - c.head_start;
    let before = (used + RESPONSE_CHUNK_BYTES - 1) / RESPONSE_CHUNK_BYTES;
    let after = (used + bytes.len + RESPONSE_CHUNK_BYTES - 1) / RESPONSE_CHUNK_BYTES;
    if after - before > pool_available(pool) { return false; }
    // A connection with no staged bytes has no chain, whatever its head field holds.
    var tail: i64 = NO_CHUNK;
    if c.wire_len > 0 {
        tail = c.head;
        while pool.next[tail] != NO_CHUNK { tail = pool.next[tail]; }
    }
    var pos: i64 = 0;
    while pos < bytes.len {
        let offset = used % RESPONSE_CHUNK_BYTES;
        if offset == 0 {
            let id = chunk_take(pool);
            pool.next[id] = NO_CHUNK;
            if tail == NO_CHUNK { c.head = id; } else { pool.next[tail] = id; }
            tail = id;
        }
        let room = RESPONSE_CHUNK_BYTES - offset;
        let left = bytes.len - pos;
        let n = if left < room { left } else { room };
        for k in n { pool.bytes[tail * RESPONSE_CHUNK_BYTES + offset + k] = bytes[pos + k]; }
        pos += n;
        used += n;
        c.wire_len += n;
    }
    c.writing = true;
    return true;
}

// Slow or unservable stream: closed at once, counted as dropped. Other streams are unaffected.
fn sse_drop(c: Connection&, control: ServerControl&, pool: ChunkPool&, inputs: InputPool&) {
    control.stats.sse_dropped += 1;
    close_connection(c, control, pool, inputs);
}

// Copies each staged publish to every stream on its channel, in publish order.
fn sse_fan_out(clients: Connection[MAX_CLIENTS]&, control: ServerControl&, pool: ChunkPool&, inputs: InputPool&, config: ServerConfig) {
    if control.sse_msg_count == 0 { return; }
    var start: i64 = 0;
    for m in control.sse_msg_count {
        let end = control.sse_msg_end[m];
        let channel = control.sse_msg_channel[m];
        for i in config.max_clients {
            let c .= clients[i];
            if c.fd < 0 || !c.sse || c.sse_closing || c.sse_channel != channel { continue; }
            if sse_queue(c, pool, sse_outbox[start..end], config.sse_max_queued_bytes) {
                control.stats.sse_sent += 1;
            } else {
                sse_drop(c, control, pool, inputs);
            }
        }
        start = end;
    }
    sse_outbox.clear();
    control.sse_msg_count = 0;
}

// Copies the messages published since this process last looked, from the shared ring, to the streams of
// this process. Without the shared store the outbox holds them instead, so this is then sse_fan_out.
fn sse_deliver(clients: Connection[MAX_CLIENTS]&, control: ServerControl&, pool: ChunkPool&, inputs: InputPool&, config: ServerConfig) {
    if !shared_enabled() {
        sse_fan_out(clients, control, pool, inputs, config);
        return;
    }
    if sse_stage.len == 0 { sse_stage.resize(MAX_SSE_OUTBOX_BYTES, 0); }
    var channel: i32 = 0;
    loop {
        var position = sse_read_position;
        var seq = sse_read_seq;
        let n = gw_shared_ring_read(position, seq, channel, sse_stage[..]);
        sse_read_position = position;
        sse_read_seq = seq;
        if n <= 0 { return; }
        sse_outbox.clear();
        sse_outbox.append(sse_stage[0..n]);
        control.sse_msg_channel[0] = channel;
        control.sse_msg_end[0] = sse_outbox.len;
        control.sse_msg_count = 1;
        sse_fan_out(clients, control, pool, inputs, config);
    }
}

// Shutdown: every stream gets the close event and the terminating chunk, then closes once flushed.
fn sse_close_all(clients: Connection[MAX_CLIENTS]&, control: ServerControl&, pool: ChunkPool&, inputs: InputPool&, config: ServerConfig) {
    var closing: u8[>..] = [];
    sse_close_chunks(closing);
    for i in config.max_clients {
        let c .= clients[i];
        if c.fd < 0 || !c.sse || c.sse_closing { continue; }
        if sse_queue(c, pool, closing[..], config.sse_max_queued_bytes + SSE_CLOSE_RESERVE_BYTES) {
            c.sse_closing = true;
        } else {
            sse_drop(c, control, pool, inputs);
        }
    }
}

// Sends queued bytes until the queue is empty or the socket would block. Sending once per poll
// would cap a busy stream at one chunk per iteration, so the stream drains in one pass instead.
fn sse_flush(c: Connection&, control: ServerControl&, pool: ChunkPool&, inputs: InputPool&) {
    while c.writing {
        let offset = c.sent - c.head_start;
        let left = c.wire_len - c.sent;
        let room = RESPONSE_CHUNK_BYTES - offset;
        let limit = if left < room { left } else { room };
        let base = c.head * RESPONSE_CHUNK_BYTES + offset;
        let n = gw_send(c.fd, pool.bytes[base..base + limit]);
        if n == IO_WOULD_BLOCK { return; }
        if n <= 0 { close_connection(c, control, pool, inputs); return; }
        c.sent += n;
        control.stats.bytes_written += n;
        if c.sent < c.wire_len {
            // A finished chunk goes back to the pool and the chain moves on.
            if c.sent - c.head_start == RESPONSE_CHUNK_BYTES {
                let next = pool.next[c.head];
                pool.free[pool.free_count] = c.head;
                pool.free_count += 1;
                c.head = next;
                c.head_start += RESPONSE_CHUNK_BYTES;
            }
        } else {
            // Everything queued is on the wire: the chain is released and the stream waits for events.
            release_chunks(c, pool);
            c.writing = false;
            if c.sse_closing { close_connection(c, control, pool, inputs); }
        }
    }
}

// One loop step for a stream. Streams have no read or idle timeout; their deadline is the next
// heartbeat. Input from the client is discarded, and EOF closes the stream.
fn sse_step(c: Connection&, control: ServerControl&, pool: ChunkPool&, inputs: InputPool&, config: ServerConfig, ready: i32, now: i64) {
    if ready < 0 { close_connection(c, control, pool, inputs); return; }
    if !c.sse_closing && now >= c.deadline {
        c.deadline = now + config.sse_heartbeat_ms * NANOSECONDS_PER_MILLISECOND;
        if !sse_queue(c, pool, SSE_PING_CHUNK, config.sse_max_queued_bytes) { sse_drop(c, control, pool, inputs); return; }
    }
    if c.writing {
        if ready == 0 { return; }
        sse_flush(c, control, pool, inputs);
        return;
    }
    if ready == 0 { return; }
    // The discarded input borrows a block for this one read only.
    input_make_room(c, inputs);
    let start = c.input_at;
    let stop = c.input_at + c.input_cap;
    let n = gw_recv(c.fd, inputs.bytes[start..stop]);
    input_detach(c, inputs);
    if n == IO_WOULD_BLOCK { return; }
    if n <= 0 { close_connection(c, control, pool, inputs); return; }
}

// Upgrades a connection after its handler called c.sse. Returns 0 when the stream started; otherwise
// the status to answer with, and the connection is closed after that answer.
fn sse_upgrade(c: Connection&, control: ServerControl&, config: ServerConfig, pool: ChunkPool&, head_buf: u8[>..]&, r: Response&, method: const u8[:], http10: bool) -> i32 {
    if http10 || method == METHOD_HEAD { return HTTP_BAD_REQUEST; }
    if control.stopping || control.shutdown_requested { return HTTP_SERVICE_UNAVAILABLE; }
    if control.stats.sse_active >= sse_client_limit(config) { return HTTP_SERVICE_UNAVAILABLE; }
    prepare_response(r);
    if r.status != HTTP_OK { return HTTP_INTERNAL_SERVER_ERROR; }
    if !stage_stream(c, pool, head_buf, r, config.write_timeout_ms) { return HTTP_SERVICE_UNAVAILABLE; }
    // With the shared store, the stream is registered where every worker can count it; a full registry refuses it.
    if shared_enabled() && gw_shared_stream_add(c.slot as i32, r.sse_channel) < 0 { return HTTP_SERVICE_UNAVAILABLE; }
    c.sse = true;
    c.sse_closing = false;
    c.sse_channel = r.sse_channel;
    c.keep = false;
    c.used = 0;
    c.pipelined = false;
    c.idle = false;
    c.deadline = clock_ns() + config.sse_heartbeat_ms * NANOSECONDS_PER_MILLISECOND;
    control.sse_slots[c.slot] = SseSlot { active: true, channel: r.sse_channel };
    control.stats.sse_active += 1;
    return 0;
}

// H(request,response), Tick(), Lifecycle(stage,stats) execute synchronously.
// Tick may capture control and call request_shutdown(). Stats reset on each run.
// Signal ownership is process-wide and opt-in: only one signal-enabled server may run.
fn serve_config<H, Tick, Lifecycle>(config: ServerConfig, control: ServerControl&) -> bool {
    if !validate_server_config(config) || control.running { return false; }
    // The shared store is made before any fork, so the single process and every worker share one layout.
    if !shared_store_open(config.shared_store_bytes) { return false; }
    shared_lock_timeout_set(config.shared_lock_timeout_ms);
    if config.workers != 1 { return serve_workers(config, control, H, Tick, Lifecycle); }
    var listener = gw_listen_config(config.port, if config.public_bind { 1 } else { 0 });
    if listener < 0 { return false; }
    if config.handle_signals && gw_signals_begin() < 0 { gw_close(listener); return false; }
    return serve_loop(config, control, listener, H, Tick, Lifecycle);
}

// The reactor on an open listener. serve_config calls it for workers = 1; a worker process calls it
// on the listener it inherited. The readiness instance is opened here, so each worker process owns
// its own (no epoll descriptor crosses fork). It returns after the listener is closed and, when
// config.handle_signals, after signal ownership is released.
fn serve_loop<H, Tick, Lifecycle>(config: ServerConfig, control: ServerControl&, inherited: i32) -> bool {
    var listener = inherited;
    if gw_reactor_open() < 0 || gw_reactor_add(LISTENER_TOKEN, listener, 0) < 0 {
        gw_reactor_close();
        gw_close(listener);
        if config.handle_signals { gw_signals_end(); }
        return false;
    }
    control.stats = default<ServerStats>();
    control.running = true;
    control.stopping = false;
    control.sse_limit = config.sse_max_queued_bytes;
    control.sse_msg_count = 0;
    sse_outbox.clear();
    // A worker reads the ring from the current end: it sees only messages published from now on.
    var head_position: i64 = 0;
    var head_seq: i64 = 0;
    gw_shared_ring_head(head_position, head_seq);
    sse_read_position = head_position;
    sse_read_seq = head_seq;
    for i in MAX_CLIENTS { control.sse_slots[i].active = false; }
    var clients: Connection[MAX_CLIENTS] = [default<Connection>(); MAX_CLIENTS];
    for i in clients.len {
        clients[i].fd = INVALID_SOCKET;
        clients[i].slot = i;
    }
    var pool = ChunkPool { count: 0, free_count: 0, max_chunks: (config.max_pool_bytes + RESPONSE_CHUNK_BYTES - 1) / RESPONSE_CHUNK_BYTES,
        free: [0; MAX_POOL_CHUNKS], next: [0; MAX_POOL_CHUNKS], bytes: [] };
    var inputs = InputPool { free_count: [0; INPUT_CLASSES], free: [0; INPUT_CLASSES * MAX_CLIENTS],
        max_bytes: config.max_request_bytes, bytes: [] };
    // One response and one head buffer serve every request. Handlers run one at a time, and
    // the body buffer is cleared after each response is staged, so its capacity is reused.
    var scratch = response();
    scratch.max_body = config.max_response_bytes;
    var head_buf: u8[>..] = [];
    var grace_deadline: i64 = 0;
    var sse_closing_begun = false;
    var success = true;
    Lifecycle(SERVER_STARTED, control.stats);
    loop {
        Tick();
        if config.handle_signals && gw_signal_pending() != 0 { request_shutdown(control); }
        if config.max_requests > UNLIMITED_REQUESTS && control.stats.completed >= config.max_requests { request_shutdown(control); }
        if control.shutdown_requested && !control.stopping {
            control.stopping = true;
            gw_reactor_remove(LISTENER_TOKEN, listener);
            gw_close(listener);
            listener = INVALID_SOCKET;
            grace_deadline = clock_ns() + config.shutdown_grace_ms * NANOSECONDS_PER_MILLISECOND;
            Lifecycle(SERVER_STOPPING, control.stats);
        }
        // Events published before the stop reach the streams before their close events.
        sse_deliver(clients, control, pool, inputs, config);
        if control.stopping && !sse_closing_begun {
            sse_closing_begun = true;
            sse_close_all(clients, control, pool, inputs, config);
        }
        if control.stopping && (control.stats.active == 0 || clock_ns() >= grace_deadline) { break; }
        for i in config.max_clients { reactor_sync(clients[i]); }
        var tokens: i32[MAX_POLL_FDS] = [0; MAX_POLL_FDS];
        var events: i32[MAX_POLL_FDS] = [0; MAX_POLL_FDS];
        var ready: i32[MAX_POLL_FDS] = [0; MAX_POLL_FDS];
        var wait_ms = config.poll_timeout_ms;
        // A long poll interval must never delay an active client deadline.
        let poll_now = clock_ns();
        for i in config.max_clients {
            if clients[i].fd < 0 { continue; }
            let remaining_ms = (clients[i].deadline - poll_now) / NANOSECONDS_PER_MILLISECOND;
            if remaining_ms < wait_ms { wait_ms = if remaining_ms > 0 { remaining_ms as i32 } else { 0 }; }
        }
        // A scheduled task due before the poll interval ends wakes the reactor on time (web::hint_wakeup).
        if control.wake_at_ns > 0 {
            let remaining_ms = (control.wake_at_ns - poll_now) / NANOSECONDS_PER_MILLISECOND;
            if remaining_ms < wait_ms { wait_ms = if remaining_ms > 0 { remaining_ms as i32 } else { 0 }; }
        }
        // Never let polling extend beyond the shutdown grace deadline.
        if control.stopping {
            let remaining_ms = (grace_deadline - clock_ns()) / NANOSECONDS_PER_MILLISECOND;
            if remaining_ms < wait_ms { wait_ms = if remaining_ms > 0 { remaining_ms as i32 } else { 0 }; }
        }
        // Only descriptors that became ready come back; they are laid out by token for the loop below.
        let count = gw_reactor_wait(tokens, events, wait_ms);
        if count < 0 { success = false; break; }
        let ready_count = count as i64;
        for e in ready_count { ready[tokens[e] as i64] = events[e]; }
        if ready[LISTENER_TOKEN] > 0 && !control.stopping {
            for attempt in ACCEPT_BUDGET {
                let fd = gw_accept(listener);
                if fd < 0 { break; }
                control.stats.accepted += 1;
                var slot: i64 = -1;
                for i in config.max_clients { if clients[i].fd < 0 { slot = i; break; } }
                if slot < 0 { gw_close(fd); control.stats.rejected += 1; }
                else if gw_reactor_add(slot as i32, fd, 0) < 0 { gw_close(fd); control.stats.rejected += 1; }
                else {
                    clients[slot].fd = fd;
                    let peer_len = gw_peer_address(fd, clients[slot].peer[..]);
                    clients[slot].peer_len = if peer_len < 0 { 0 } else { peer_len };
                    clients[slot].deadline = clock_ns() + config.read_timeout_ms * NANOSECONDS_PER_MILLISECOND;
                    control.stats.active += 1;
                }
            }
        }
        let now = clock_ns();
        for i in config.max_clients {
            let c .= clients[i];
            if c.fd < 0 { continue; }
            if c.sse {
                sse_step(c, control, pool, inputs, config, ready[i], now);
                continue;
            }
            if now >= c.deadline {
                // Idle keep-alive expiry is silent; a request left half-received is a timeout.
                if !c.idle { control.stats.timeouts += 1; }
                close_connection(c, control, pool, inputs);
                continue;
            }
            // Shutdown ends idle connections at once; in-flight requests still finish.
            if control.stopping && !c.writing && c.used == 0 { close_connection(c, control, pool, inputs); continue; }
            if ready[i] < 0 { close_connection(c, control, pool, inputs); continue; }
            if c.writing {
                if ready[i] == 0 { continue; }
                // Send from the head chunk; it holds bytes [head_start, head_start + C) of the wire, or up to wire end.
                let offset = c.sent - c.head_start;
                let left = c.wire_len - c.sent;
                let room = RESPONSE_CHUNK_BYTES - offset;
                let limit = if left < room { left } else { room };
                let base = c.head * RESPONSE_CHUNK_BYTES + offset;
                let n = gw_send(c.fd, pool.bytes[base..base + limit]);
                if n == IO_WOULD_BLOCK { continue; }
                if n <= 0 { close_connection(c, control, pool, inputs); continue; }
                c.sent += n;
                control.stats.bytes_written += n;
                if c.sent < c.wire_len {
                    // A finished chunk goes back to the pool and the chain moves on.
                    if c.sent - c.head_start == RESPONSE_CHUNK_BYTES {
                        let next = pool.next[c.head];
                        pool.free[pool.free_count] = c.head;
                        pool.free_count += 1;
                        c.head = next;
                        c.head_start += RESPONSE_CHUNK_BYTES;
                    }
                    continue;
                }
                control.stats.completed += 1;
                release_chunks(c, pool);
                c.writing = false;
                // Keep-alive only when this response left the connection open and shutdown has not begun.
                if !c.keep || control.stopping { close_connection(c, control, pool, inputs); continue; }
                if c.used > 0 {
                    // Pipelined bytes are already buffered; parse them without waiting for poll.
                    c.pipelined = true;
                    c.idle = false;
                    c.deadline = clock_ns() + config.read_timeout_ms * NANOSECONDS_PER_MILLISECOND;
                } else {
                    c.idle = true;
                    c.deadline = clock_ns() + config.idle_timeout_ms * NANOSECONDS_PER_MILLISECOND;
                    continue;
                }
            }
            if !c.pipelined {
                if ready[i] == 0 { continue; }
                let first_byte = c.used == 0;
                input_make_room(c, inputs);
                if c.used >= c.input_cap { close_connection(c, control, pool, inputs); continue; }
                let start = c.input_at + c.used;
                let stop = c.input_at + c.input_cap;
                let n = gw_recv(c.fd, inputs.bytes[start..stop]);
                if n == IO_WOULD_BLOCK { continue; }
                if n <= 0 { close_connection(c, control, pool, inputs); continue; }
                // The read timeout restarts at each request's first byte, not per fragment.
                if first_byte {
                    c.idle = false;
                    c.deadline = clock_ns() + config.read_timeout_ms * NANOSECONDS_PER_MILLISECOND;
                }
                c.used += n;
                control.stats.bytes_read += n;
            }
            c.pipelined = false;
            let parsed, parsed_status = parse_request(inputs.bytes[c.input_at..c.input_at + c.used]);
            var request = parsed;
            request.peer = c.peer[..c.peer_len];
            var status = parsed_status;
            if status == PARSE_INCOMPLETE && c.used >= config.max_request_bytes {
                status = if find(inputs.bytes[c.input_at..c.input_at + c.used], "\r\n\r\n") < 0 { HTTP_REQUEST_HEADER_FIELDS_TOO_LARGE } else { HTTP_CONTENT_TOO_LARGE };
            }
            if status == PARSE_INCOMPLETE { continue; }
            // scratch is empty here: the previous response was reset after staging.
            record_pressure(config, control, pool);
            if status == HTTP_OK { H(request, scratch); }
            else { scratch.status = status; set_body(scratch, reason(status)); }
            if status == HTTP_OK && scratch.sse {
                let refused = sse_upgrade(c, control, config, pool, head_buf, scratch, request.method, request_http10(inputs.bytes[c.input_at..c.input_at + c.used]));
                reset_response(scratch);
                // A stream never reads its input back, so the request bytes and their block are released now.
                c.used = 0;
                input_detach(c, inputs);
                if refused == 0 { continue; }
                scratch.status = refused;
                set_body(scratch, reason(refused));
                let answered = stage_response(c, pool, head_buf, scratch, false, true, false, config.write_timeout_ms);
                reset_response(scratch);
                if !answered { close_connection(c, control, pool, inputs); continue; }
                c.keep = false;
                continue;
            }
            // Parser errors always close: the byte boundary of the next request is unknown.
            let http10 = status == HTTP_OK && request_http10(inputs.bytes[c.input_at..c.input_at + c.used]);
            let head = status == HTTP_OK && request.method == METHOD_HEAD;
            var keep = false;
            // A handler may request shutdown mid-response; that response must already say close.
            if status == HTTP_OK && config.keep_alive && !control.stopping && !control.shutdown_requested {
                let last_on_connection = config.max_requests_per_connection > UNLIMITED_REQUESTS &&
                    c.served + 1 >= config.max_requests_per_connection;
                let last_on_server = config.max_requests > UNLIMITED_REQUESTS &&
                    control.stats.completed + 1 >= config.max_requests;
                if !last_on_connection && !last_on_server {
                    keep = if http10 {
                        request_connection_has(request, CONNECTION_KEEP_ALIVE) && !request_connection_has(request, CONNECTION_CLOSE)
                    } else {
                        !request_connection_has(request, CONNECTION_CLOSE)
                    };
                }
            }
            if c.served > 0 { control.stats.reused += 1; }
            c.served += 1;
            let consumed = if status == HTTP_OK { find(inputs.bytes[c.input_at..c.input_at + c.used], "\r\n\r\n") + 4 + request.body.len } else { c.used };
            var staged = stage_response(c, pool, head_buf, scratch, head, !keep, keep && http10, config.write_timeout_ms);
            if !staged {
                // The pool is full of in-flight responses. Answer 503 and close, which fits in a chunk.
                keep = false;
                reset_response(scratch);
                scratch.status = HTTP_SERVICE_UNAVAILABLE;
                set_body(scratch, "Service Unavailable\n");
                staged = stage_response(c, pool, head_buf, scratch, false, true, false, config.write_timeout_ms);
            }
            reset_response(scratch);
            if !staged { close_connection(c, control, pool, inputs); continue; }
            c.keep = keep;
            // The response is staged, so the request bytes are no longer read. An idle connection gives its block back.
            if keep { consume_input(c, inputs, consumed); } else { c.used = 0; }
            if c.used == 0 { input_detach(c, inputs); }
        }
    }
    if !control.stopping {
        control.stopping = true;
        Lifecycle(SERVER_STOPPING, control.stats);
    }
    for i in clients.len {
        if clients[i].fd >= 0 { control.stats.forced_closes += 1; }
        close_connection(clients[i], control, pool, inputs);
    }
    sse_outbox.clear();
    control.sse_msg_count = 0;
    gw_reactor_remove(LISTENER_TOKEN, listener);
    gw_close(listener);
    gw_reactor_close();
    if config.handle_signals { gw_signals_end(); }
    control.running = false;
    Lifecycle(SERVER_STOPPED, control.stats);
    return success;
}

// ---- Worker processes (workers != 1) -------------------------------------------------------
// The parent opens the listener and owns SIGINT/SIGTERM, and it never serves. It forks each worker,
// which inherits the listener and runs serve_loop with workers = 1, handle_signals = true and the
// ignore_lifecycle callback. A worker writes its ServerStats to a pipe when it stops; the parent
// sums those records into control.stats, which SERVER_STOPPED reports. See docs/api.md.
// Worker callbacks (H, Tick) run in the workers; the parent runs Tick and the lifecycle stages.
// The pipe moves opaque frames of STATS_RECORD_BYTES; the layout lives in encode_stats/decode_stats.
extern "gw_pipe_write_record" fn write_record(fd: i32, frame: const u8[:]) -> i64;
extern "gw_pipe_read_record" fn read_record(fd: i32, frame: u8[:]) -> i64;

struct WorkerSlot { pid: i32, started: i64, spawn_at: i64, backoff_ms: i64 }

// The number of fields in T, counted by a const for over fields<T>.
fn stats_field_count<T>() -> i64 {
    var count: i64 = 0;
    const for <N, A> in fields<T> { count += 1; }
    return count;
}

// One i64 as eight little-endian bytes at frame[at..at+8].
fn stats_put_word(frame: u8[:], at: i64, value: i64) {
    let bits = value as! u64; // a bit pattern: negative values are not a range error here
    for k in 8 { frame[at + k] = ((bits >> (k * 8)) & 0xff) as u8; }
}

fn stats_get_word(frame: const u8[:], at: i64) -> i64 {
    var bits: u64 = 0;
    for k in 8 {
        let byte: u64 = frame[at + k];
        bits |= byte << (k * 8);
    }
    return bits as! i64;
}

// Writes stats as one frame: the magic, the field count, then every field in declaration order.
// False when the frame is not STATS_RECORD_BYTES long or the struct has more fields than fit.
fn encode_stats(stats: ServerStats, frame: u8[:]) -> bool {
    let count = stats_field_count<ServerStats>();
    if count > STATS_FIELD_CAPACITY || frame.len != STATS_RECORD_BYTES { return false; }
    for i in STATS_RECORD_BYTES { frame[i] = 0; }
    stats_put_word(frame, 0, STATS_RECORD_MAGIC);
    stats_put_word(frame, 8, count);
    var at: i64 = STATS_HEADER_BYTES;
    const for <N, A> in fields<ServerStats> {
        stats_put_word(frame, at, stats.A);
        at += STATS_FIELD_BYTES;
    }
    return true;
}

// Reads a frame back into stats. False, with stats unchanged, when the frame is not a ServerStats
// record of this layout: wrong length, wrong magic, or a field count other than this build's.
fn decode_stats(frame: const u8[:], stats: ServerStats&) -> bool {
    if frame.len != STATS_RECORD_BYTES { return false; }
    if stats_get_word(frame, 0) != STATS_RECORD_MAGIC { return false; }
    if stats_get_word(frame, 8) != stats_field_count<ServerStats>() { return false; }
    var decoded = default<ServerStats>();
    var at: i64 = STATS_HEADER_BYTES;
    const for <N, A> in fields<ServerStats> {
        decoded.A = stats_get_word(frame, at);
        at += STATS_FIELD_BYTES;
    }
    stats = decoded;
    return true;
}

// Every field is summed, so a field added to ServerStats is aggregated without edits here.
fn add_stats(total: ServerStats&, s: ServerStats) {
    const for <N, A> in fields<ServerStats> { total.A += s.A; }
}

// Reads every complete stats frame waiting on the pipe into control.stats. A frame that does not
// decode is dropped; frames are fixed-size, so the pipe stays aligned on the next one.
fn collect_worker_stats(read_end: i32, control: ServerControl&) {
    var frame: u8[STATS_RECORD_BYTES] = [0; STATS_RECORD_BYTES];
    var record = default<ServerStats>();
    loop {
        if read_record(read_end, frame[..]) != STATS_RECORD_BYTES { break; }
        if decode_stats(frame[..], record) { add_stats(control.stats, record); }
    }
}

// Forks one worker. The parent gets the child's pid, or -1 when fork fails. The child serves
// until it stops, reports its stats and exits; it never returns from this function.
fn spawn_worker<H, Tick, Lifecycle>(config: ServerConfig, control: ServerControl&, listener: i32,
        read_end: i32, write_end: i32) -> i32 {
    let pid = fork_process();
    if pid != 0 { return pid; }
    gw_close(read_end);
    worker_process = true;
    // The inherited handlers are the parent's; restore the originals, then take this worker's own.
    gw_signals_end();
    if gw_signals_begin() < 0 { exit(1); }
    var worker = config;
    worker.workers = 1;
    worker.handle_signals = true;
    let ok = serve_loop(worker, control, listener, H, Tick, ignore_lifecycle);
    var frame: u8[STATS_RECORD_BYTES] = [0; STATS_RECORD_BYTES];
    if encode_stats(control.stats, frame[..]) { write_record(write_end, frame[..]); }
    gw_close(write_end);
    if ok { exit(0); }
    exit(1);
}

// Preforked workers. The listener is opened once, here, and every worker accepts from it.
// Restarts follow the policy in runtime/constants (backoff, restart budget). When the budget is
// spent, or fork fails, the whole server stops and returns false.
fn serve_workers<H, Tick, Lifecycle>(config: ServerConfig, control: ServerControl&) -> bool {
    var listener = gw_listen_config(config.port, if config.public_bind { 1 } else { 0 });
    if listener < 0 { return false; }
    if gw_signals_begin() < 0 { gw_close(listener); return false; }
    var read_end: i32 = INVALID_SOCKET;
    var write_end: i32 = INVALID_SOCKET;
    if stats_pipe(read_end, write_end) < 0 { gw_signals_end(); gw_close(listener); return false; }
    var wanted: i64 = config.workers;
    if wanted == 0 { wanted = cpu_count(); }
    control.stats = default<ServerStats>();
    control.running = true;
    control.stopping = false;
    var slots: WorkerSlot[MAX_WORKERS] = [default<WorkerSlot>(); MAX_WORKERS];
    for i in wanted { slots[i].pid = 0; slots[i].backoff_ms = WORKER_BACKOFF_MIN_MS; }
    var restarts: i64[WORKER_RESTART_BUDGET] = [0; WORKER_RESTART_BUDGET];
    var restart_count: i64 = 0;
    var success = true;
    var stopping = false;
    var killed = false;
    var grace_deadline: i64 = 0;
    for i in wanted {
        let pid = spawn_worker(config, control, listener, read_end, write_end, H, Tick, Lifecycle);
        if pid < 0 { success = false; control.shutdown_requested = true; break; }
        slots[i].pid = pid;
        slots[i].started = clock_ns();
    }
    Lifecycle(SERVER_STARTED, control.stats);
    loop {
        Tick();
        if gw_signal_pending() != 0 { request_shutdown(control); }
        let now = clock_ns();
        if control.shutdown_requested && !stopping {
            stopping = true;
            control.stopping = true;
            gw_close(listener);
            listener = INVALID_SOCKET;
            grace_deadline = now + (config.shutdown_grace_ms + WORKER_KILL_MARGIN_MS) * NANOSECONDS_PER_MILLISECOND;
            Lifecycle(SERVER_STOPPING, control.stats);
            for i in wanted { if slots[i].pid > 0 { signal_process(slots[i].pid, SIGNAL_TERM); } }
        }
        // Reap workers that stopped. One that stopped unasked is restarted after its backoff.
        for i in wanted {
            if slots[i].pid <= 0 { continue; }
            var status: i32 = 0;
            if wait_child(slots[i].pid, status) == 0 { continue; }
            slots[i].pid = 0;
            if stopping { continue; }
            if now - slots[i].started >= WORKER_STABLE_MS * NANOSECONDS_PER_MILLISECOND {
                slots[i].backoff_ms = WORKER_BACKOFF_MIN_MS;
            }
            let window_start = now - WORKER_RESTART_WINDOW_MS * NANOSECONDS_PER_MILLISECOND;
            var kept: i64 = 0;
            for k in restart_count {
                if restarts[k] >= window_start { restarts[kept] = restarts[k]; kept += 1; }
            }
            restart_count = kept;
            if restart_count >= config.worker_restart_budget {
                // Use our native writer: applications need not import the os stdlib.
                write_record(2, "goose-web: workers kept exiting and the restart budget is spent; the server stops\n");
                success = false;
                control.shutdown_requested = true;
                continue;
            }
            restarts[restart_count] = now;
            restart_count += 1;
            slots[i].spawn_at = now + slots[i].backoff_ms * NANOSECONDS_PER_MILLISECOND;
            slots[i].backoff_ms = if slots[i].backoff_ms * 2 > WORKER_BACKOFF_MAX_MS { WORKER_BACKOFF_MAX_MS } else { slots[i].backoff_ms * 2 };
        }
        if !stopping {
            for i in wanted {
                if slots[i].pid != 0 || now < slots[i].spawn_at { continue; }
                let pid = spawn_worker(config, control, listener, read_end, write_end, H, Tick, Lifecycle);
                if pid < 0 { success = false; control.shutdown_requested = true; break; }
                slots[i].pid = pid;
                slots[i].started = now;
            }
        }
        var wait_ms = WORKER_SUPERVISE_MS as i32;
        if stopping {
            let remaining_ms = (grace_deadline - clock_ns()) / NANOSECONDS_PER_MILLISECOND;
            if remaining_ms < wait_ms { wait_ms = if remaining_ms > 0 { remaining_ms as i32 } else { 0 }; }
        }
        wait_readable(read_end, wait_ms);
        collect_worker_stats(read_end, control);
        if stopping {
            var live = false;
            for i in wanted { if slots[i].pid > 0 { live = true; } }
            if !live { break; }
            if !killed && clock_ns() >= grace_deadline {
                killed = true;
                for i in wanted { if slots[i].pid > 0 { signal_process(slots[i].pid, SIGNAL_KILL); } }
            }
        }
    }
    collect_worker_stats(read_end, control);
    gw_close(read_end);
    gw_close(write_end);
    gw_close(listener);
    gw_signals_end();
    control.stopping = true;
    control.running = false;
    Lifecycle(SERVER_STOPPED, control.stats);
    return success;
}

fn ignore_lifecycle(stage: i32, stats: ServerStats) {}
// Compatibility entry point: loopback binding and the original five-second limits.
fn serve<H, Tick>(port: i32 = DEFAULT_PORT, max_requests: i64 = UNLIMITED_REQUESTS) -> bool {
    var config = server_config();
    config.port = port;
    config.max_requests = max_requests;
    var control = default<ServerControl>();
    return serve_config(config, control, H, Tick, ignore_lifecycle);
}

// Publishes one event to every stream subscribed to channel. The message is framed here and
// staged in sse_outbox; the reactor copies it into each stream at its next iteration. Returns the
// number of streams on the channel when the message was accepted, 0 when nothing can receive it
// (not running, stopping, or no subscriber), and -1 when it is refused: an invalid event name,
// a message over sse_max_queued_bytes or MAX_SSE_MESSAGE_BYTES, or a full outbox. With the shared
// store the count covers the streams of every worker, and the message goes to the shared ring.
fn sse_publish(control: ServerControl&, channel: i32, event: const u8[:], data: const u8[:]) -> i64 {
    if !control.running || control.stopping { return 0; }
    if !sse_event_valid(event) || data.len > MAX_SSE_MESSAGE_BYTES { return -1; }
    // With the shared store, subscribers are counted in every worker, and the message goes to the shared ring.
    let shared = shared_enabled();
    var subscribers: i64 = 0;
    if shared {
        subscribers = gw_shared_stream_count(channel);
        if subscribers < 0 { return -1; }
    } else {
        for s in control.sse_slots {
            if s.active && s.channel == channel { subscribers += 1; }
        }
    }
    if subscribers == 0 { return 0; }
    if !shared && control.sse_msg_count == MAX_SSE_OUTBOX_MESSAGES { return -1; }
    var message: u8[>..] = [];
    if !sse_format_message(message, event, data) { return -1; }
    var framed: u8[>..] = [];
    sse_frame(framed, message[..]);
    if framed.len > control.sse_limit || framed.len > MAX_SSE_OUTBOX_BYTES { return -1; }
    if shared {
        if gw_shared_ring_push(channel, framed[..]) < 0 { return -1; }
        return subscribers;
    }
    if sse_outbox.len + framed.len > MAX_SSE_OUTBOX_BYTES { return -1; }
    sse_outbox.append(framed[..]);
    control.sse_msg_channel[control.sse_msg_count] = channel;
    control.sse_msg_count += 1;
    control.sse_msg_end[control.sse_msg_count - 1] = sse_outbox.len;
    return subscribers;
}
