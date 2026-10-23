import src.constants.runtime;
import src.constants.http;
import src.constants.limits;
import src.http.request;
import src.http.response;
import src.http.errors;
import std;
import src.sys.process;
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
    handle_signals: bool
}
struct ServerStats {
    accepted: i64, active: i64, completed: i64, rejected: i64,
    timeouts: i64, forced_closes: i64, bytes_read: i64, bytes_written: i64, reused: i64
}
struct ServerControl {
    shutdown_requested: bool, running: bool, stopping: bool, stats: ServerStats
}
fn server_config() -> ServerConfig {
    return ServerConfig { port: DEFAULT_PORT, public_bind: DEFAULT_PUBLIC_BIND, max_clients: DEFAULT_MAX_CLIENTS,
        max_request_bytes: DEFAULT_MAX_REQUEST_BYTES, max_response_bytes: DEFAULT_MAX_RESPONSE_BYTES,
        read_timeout_ms: DEFAULT_READ_TIMEOUT_MS, write_timeout_ms: DEFAULT_WRITE_TIMEOUT_MS,
        idle_timeout_ms: DEFAULT_IDLE_TIMEOUT_MS, poll_timeout_ms: DEFAULT_POLL_TIMEOUT_MS,
        shutdown_grace_ms: DEFAULT_SHUTDOWN_GRACE_MS, max_requests: UNLIMITED_REQUESTS,
        max_requests_per_connection: DEFAULT_MAX_REQUESTS_PER_CONNECTION, keep_alive: DEFAULT_KEEP_ALIVE,
        handle_signals: DEFAULT_HANDLE_SIGNALS };
}
// Millisecond durations are capped at one day to keep nanosecond arithmetic safe.
fn validate_server_config(c: ServerConfig) -> bool {
    return c.port >= MIN_PORT && c.port <= MAX_PORT && c.max_clients >= 1 && c.max_clients <= MAX_CLIENTS &&
        c.max_request_bytes >= 1 && c.max_request_bytes <= MAX_REQUEST_BYTES &&
        c.max_response_bytes >= 1 && c.max_response_bytes <= MAX_RESPONSE_BODY_BYTES &&
        c.max_requests >= UNLIMITED_REQUESTS &&
        c.max_requests_per_connection >= UNLIMITED_REQUESTS && c.max_requests_per_connection <= MAX_REQUESTS_PER_CONNECTION &&
        c.read_timeout_ms >= 1 && c.read_timeout_ms <= MAX_TIMEOUT_MS &&
        c.write_timeout_ms >= 1 && c.write_timeout_ms <= MAX_TIMEOUT_MS &&
        c.idle_timeout_ms >= 1 && c.idle_timeout_ms <= MAX_TIMEOUT_MS &&
        c.poll_timeout_ms >= 1 && c.poll_timeout_ms <= MAX_POLL_TIMEOUT_MS &&
        c.shutdown_grace_ms >= 0 && c.shutdown_grace_ms <= MAX_TIMEOUT_MS;
}
fn request_shutdown(control: ServerControl&) { control.shutdown_requested = true; }
extern fn gw_accept(listener: i32) -> i32;
extern fn gw_recv(fd: i32, buffer: u8[:]) -> i64;
extern fn gw_send(fd: i32, buffer: const u8[:]) -> i64;
extern fn gw_poll(fds: const i32[:], interests: const i32[:], ready: i32[:], timeout: i32) -> i32;
extern fn gw_close(fd: i32);

// Shared store for serialized responses. Chunk k is bytes [k*C, (k+1)*C) of bytes.
// Freed chunks are reused, so memory tracks the peak of in-flight response bytes.
// Bounded by MAX_CLIENTS * MAX_RESPONSE_CHUNKS, the most chunks any slot set can hold.
const MAX_POOL_CHUNKS = MAX_CLIENTS * MAX_RESPONSE_CHUNKS;
struct ChunkPool {
    count: i64, free_count: i64, free: i64[MAX_POOL_CHUNKS], bytes: u8[>..]
}
struct Connection {
    fd: i32, used: i64, sent: i64, wire_len: i64, writing: bool, keep: bool, pipelined: bool,
    idle: bool, deadline: i64, served: i64, chunk_count: i64, chunks: i64[MAX_RESPONSE_CHUNKS],
    input: u8[MAX_REQUEST_BYTES]
}

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

fn release_chunks(c: Connection&, pool: ChunkPool&) {
    for i in c.chunk_count {
        pool.free[pool.free_count] = c.chunks[i];
        pool.free_count += 1;
    }
    c.chunk_count = 0;
    c.wire_len = 0;
    c.sent = 0;
}

fn close_connection(c: Connection&, stats: ServerStats&, pool: ChunkPool&) {
    if c.fd >= 0 { stats.active -= 1; }
    gw_close(c.fd);
    c.fd = INVALID_SOCKET;
    release_chunks(c, pool);
    c.used = 0;
    c.writing = false;
    c.keep = false;
    c.pipelined = false;
    c.idle = false;
    c.served = 0;
}

// Serializes r into the pool and arms the write phase. Consumes the request bytes
// before `consumed` on keep-alive, so the next pipelined request starts at index 0.
fn stage_response(c: Connection&, pool: ChunkPool&, r: Response&, head: bool, close: bool, keep_alive: bool, timeout_ms: i64) {
    var wire: u8[>..] = [];
    serialize_response(wire, r, head, close, keep_alive);
    release_chunks(c, pool);
    var pos: i64 = 0;
    while pos < wire.len {
        let id = chunk_take(pool);
        let n = if wire.len - pos < RESPONSE_CHUNK_BYTES { wire.len - pos } else { RESPONSE_CHUNK_BYTES };
        for i in n { pool.bytes[id * RESPONSE_CHUNK_BYTES + i] = wire[pos + i]; }
        c.chunks[c.chunk_count] = id;
        c.chunk_count += 1;
        pos += n;
    }
    c.wire_len = wire.len;
    c.sent = 0;
    c.writing = true;
    c.deadline = clock_ns() + timeout_ms * NANOSECONDS_PER_MILLISECOND;
}

// Drops the first `consumed` bytes of input. Bytes move forward, so overlap is safe.
fn consume_input(c: Connection&, consumed: i64) {
    for i in c.used - consumed { c.input[i] = c.input[consumed + i]; }
    c.used -= consumed;
}

// H(request,response), Tick(), Lifecycle(stage,stats) execute synchronously.
// Tick may capture control and call request_shutdown(). Stats reset on each run.
// Signal ownership is process-wide and opt-in: only one signal-enabled server may run.
fn serve_config<H, Tick, Lifecycle>(config: ServerConfig, control: ServerControl&) -> bool {
    if !validate_server_config(config) || control.running { return false; }
    var listener = gw_listen_config(config.port, if config.public_bind { 1 } else { 0 });
    if listener < 0 { return false; }
    if config.handle_signals && gw_signals_begin() < 0 { gw_close(listener); return false; }
    control.stats = default<ServerStats>();
    control.running = true;
    control.stopping = false;
    var clients: Connection[MAX_CLIENTS] = [default<Connection>(); MAX_CLIENTS];
    for i in clients.len { clients[i].fd = INVALID_SOCKET; }
    var pool = ChunkPool { count: 0, free_count: 0, free: [0; MAX_POOL_CHUNKS], bytes: [] };
    var grace_deadline: i64 = 0;
    var success = true;
    Lifecycle(SERVER_STARTED, control.stats);
    loop {
        Tick();
        if config.handle_signals && gw_signal_pending() != 0 { request_shutdown(control); }
        if config.max_requests > UNLIMITED_REQUESTS && control.stats.completed >= config.max_requests { request_shutdown(control); }
        if control.shutdown_requested && !control.stopping {
            control.stopping = true;
            gw_close(listener);
            listener = INVALID_SOCKET;
            grace_deadline = clock_ns() + config.shutdown_grace_ms * NANOSECONDS_PER_MILLISECOND;
            Lifecycle(SERVER_STOPPING, control.stats);
        }
        if control.stopping && (control.stats.active == 0 || clock_ns() >= grace_deadline) { break; }
        var fds: i32[MAX_POLL_FDS] = [INVALID_SOCKET; MAX_POLL_FDS];
        var interests: i32[MAX_POLL_FDS] = [POLL_READ; MAX_POLL_FDS];
        var ready: i32[MAX_POLL_FDS] = [0; MAX_POLL_FDS];
        fds[0] = listener;
        for i in config.max_clients {
            fds[i + 1] = clients[i].fd;
            interests[i + 1] = if clients[i].writing { POLL_WRITE } else { POLL_READ };
        }
        var wait_ms = config.poll_timeout_ms;
        // A long poll interval must never delay an active client deadline.
        let poll_now = clock_ns();
        for i in config.max_clients {
            if clients[i].fd < 0 { continue; }
            let remaining_ms = (clients[i].deadline - poll_now) / NANOSECONDS_PER_MILLISECOND;
            if remaining_ms < wait_ms { wait_ms = if remaining_ms > 0 { remaining_ms as i32 } else { 0 }; }
        }
        // Never let polling extend beyond the shutdown grace deadline.
        if control.stopping {
            let remaining_ms = (grace_deadline - clock_ns()) / NANOSECONDS_PER_MILLISECOND;
            if remaining_ms < wait_ms { wait_ms = if remaining_ms > 0 { remaining_ms as i32 } else { 0 }; }
        }
        if gw_poll(fds, interests, ready, wait_ms) < 0 { success = false; break; }
        if ready[0] > 0 && !control.stopping {
            for attempt in ACCEPT_BUDGET {
                let fd = gw_accept(listener);
                if fd < 0 { break; }
                control.stats.accepted += 1;
                var slot: i64 = -1;
                for i in config.max_clients { if clients[i].fd < 0 { slot = i; break; } }
                if slot < 0 { gw_close(fd); control.stats.rejected += 1; }
                else {
                    clients[slot].fd = fd;
                    clients[slot].deadline = clock_ns() + config.read_timeout_ms * NANOSECONDS_PER_MILLISECOND;
                    control.stats.active += 1;
                }
            }
        }
        let now = clock_ns();
        for i in config.max_clients {
            let c .= clients[i];
            if c.fd < 0 { continue; }
            if now >= c.deadline {
                // Idle keep-alive expiry is silent; a request left half-received is a timeout.
                if !c.idle { control.stats.timeouts += 1; }
                close_connection(c, control.stats, pool);
                continue;
            }
            // Shutdown ends idle connections at once; in-flight requests still finish.
            if control.stopping && !c.writing && c.used == 0 { close_connection(c, control.stats, pool); continue; }
            if ready[i + 1] < 0 { close_connection(c, control.stats, pool); continue; }
            if c.writing {
                if ready[i + 1] == 0 { continue; }
                // Send from the chunk holding byte `sent`; the chunk's bytes end at chunk end or wire end.
                let offset = c.sent % RESPONSE_CHUNK_BYTES;
                let base = c.chunks[c.sent / RESPONSE_CHUNK_BYTES] * RESPONSE_CHUNK_BYTES;
                let left = c.wire_len - c.sent;
                let limit = if left < RESPONSE_CHUNK_BYTES - offset { left } else { RESPONSE_CHUNK_BYTES - offset };
                let n = gw_send(c.fd, pool.bytes[base + offset..base + offset + limit]);
                if n == IO_WOULD_BLOCK { continue; }
                if n <= 0 { close_connection(c, control.stats, pool); continue; }
                c.sent += n;
                control.stats.bytes_written += n;
                if c.sent < c.wire_len { continue; }
                control.stats.completed += 1;
                release_chunks(c, pool);
                c.writing = false;
                // Keep-alive only when this response left the connection open and shutdown has not begun.
                if !c.keep || control.stopping { close_connection(c, control.stats, pool); continue; }
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
                if ready[i + 1] == 0 { continue; }
                let first_byte = c.used == 0;
                let n = gw_recv(c.fd, c.input[c.used..config.max_request_bytes]);
                if n == IO_WOULD_BLOCK { continue; }
                if n <= 0 { close_connection(c, control.stats, pool); continue; }
                // The read timeout restarts at each request's first byte, not per fragment.
                if first_byte {
                    c.idle = false;
                    c.deadline = clock_ns() + config.read_timeout_ms * NANOSECONDS_PER_MILLISECOND;
                }
                c.used += n;
                control.stats.bytes_read += n;
            }
            c.pipelined = false;
            let request, parsed_status = parse_request(c.input[..c.used]);
            var status = parsed_status;
            if status == PARSE_INCOMPLETE && c.used >= config.max_request_bytes {
                status = if find(c.input[..c.used], "\r\n\r\n") < 0 { HTTP_REQUEST_HEADER_FIELDS_TOO_LARGE } else { HTTP_CONTENT_TOO_LARGE };
            }
            if status == PARSE_INCOMPLETE { continue; }
            var r = response();
            if status == HTTP_OK { H(request, r); }
            else { r.status = status; r.body = reason(status); }
            if r.body.len > config.max_response_bytes {
                application_error(r, HTTP_INTERNAL_SERVER_ERROR, "response_too_large", "Response body exceeds configured limit");
            }
            // Parser errors always close: the byte boundary of the next request is unknown.
            let http10 = status == HTTP_OK && request_http10(c.input[..c.used]);
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
            let consumed = if status == HTTP_OK { find(c.input[..c.used], "\r\n\r\n") + 4 + request.body.len } else { c.used };
            stage_response(c, pool, r, head, !keep, keep && http10, config.write_timeout_ms);
            c.keep = keep;
            if keep { consume_input(c, consumed); }
        }
    }
    if !control.stopping {
        control.stopping = true;
        Lifecycle(SERVER_STOPPING, control.stats);
    }
    for i in clients.len {
        if clients[i].fd >= 0 { control.stats.forced_closes += 1; }
        close_connection(clients[i], control.stats, pool);
    }
    gw_close(listener);
    if config.handle_signals { gw_signals_end(); }
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
