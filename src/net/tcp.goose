import src.constants.runtime;
import src.constants.tcp;
import src.sys.process;
import std;
namespace web;

// A nonblocking TCP server and client loop for custom protocols, beside the HTTP server. It runs on
// its own readiness instance (native/posix/net.c) and reuses the listener, accept, recv and send calls
// of native/posix/transport.c. The shared C names are declared under Goose names of their own, since
// src/runtime/server.goose already declares the originals in this namespace.

extern "gw_listen_config" fn tcp_listen(port: i32, public_bind: i32) -> i32;
extern "gw_accept" fn tcp_accept(listener: i32) -> i32;
extern "gw_peer_address" fn tcp_peer_address(fd: i32, out: u8[:]) -> i64;
extern "gw_recv" fn tcp_recv(fd: i32, buffer: u8[:]) -> i64;
extern "gw_send" fn tcp_send_bytes(fd: i32, buffer: const u8[:]) -> i64;
extern "gw_close" fn tcp_close_fd(fd: i32);
extern "gw_signals_begin" fn tcp_signals_begin() -> i32;
extern "gw_signal_pending" fn tcp_signal_pending() -> i32;
extern "gw_signals_end" fn tcp_signals_end();
extern "gw_tcp_reactor_open" fn tcp_reactor_open(capacity: i32) -> i32;
extern "gw_tcp_reactor_close" fn tcp_reactor_close();
extern "gw_tcp_add" fn tcp_register(token: i32, fd: i32, interest: i32) -> i32;
extern "gw_tcp_set_interest" fn tcp_set_interest(token: i32, fd: i32, interest: i32) -> i32;
extern "gw_tcp_remove" fn tcp_unregister(token: i32, fd: i32);
extern "gw_tcp_wait" fn tcp_wait(tokens: i32[:], ready: i32[:], timeout: i32) -> i32;
extern "gw_tcp_connect_begin" fn tcp_connect_begin(host: const u8[:], port: i32) -> i32;
extern "gw_tcp_connect_result" fn tcp_connect_result(fd: i32) -> i32;
extern "gw_tcp_half_close" fn tcp_half_close(fd: i32) -> i32;

// Working limits. Every field is checked by tcp_config_valid before a server starts.
// max_conns: connection slots, at most TCP_MAX_CONNS. read_buffer_bytes: one shared receive buffer; a Data
// view is valid only during its event. max_write_queue_bytes: the most unsent bytes per connection; reads
// pause at half of it and resume once it drains below. idle_timeout_ms: 0 disables it. workers are not
// supported: the TCP loop runs in one process (see docs/api.md).
struct TcpConfig {
    port: i32, public_bind: bool, max_conns: i64, read_buffer_bytes: i64, max_write_queue_bytes: i64,
    idle_timeout_ms: i64, connect_timeout_ms: i64, shutdown_grace_ms: i64, poll_timeout_ms: i32,
    handle_signals: bool
}

// Events delivered to the handler, in the order they happen for each connection:
// Open (accepted or connected), any number of Data, and Closed last. Writable follows a pause.
enum TcpEvent {
    Open { conn: i64 },
    Data { conn: i64, bytes: const u8[:] },
    Writable { conn: i64 },
    Closed { conn: i64, reason: i64 },
}

struct TcpStats {
    accepted: i64, active: i64, connects: i64, closed: i64, rejected: i64, timeouts: i64,
    bytes_read: i64, bytes_written: i64, refused_sends: i64
}

// One connection slot. The output queue is a chain of pool chunks: head holds bytes from head_start,
// and the queued bytes run from sent to wire. The peer text is fixed inline storage.
// paused: reads stopped because the queue reached high water (internal); full: the queue reached high
// water and Writable is owed when it drains; app_paused: the handler stopped reads (tcp_pause_reads).
struct TcpSlot {
    state: i64, gen: i64, fd: i32, interest: i64, tag: i64, deadline: i64, reason: i64,
    paused: bool, full: bool, app_paused: bool, head: i64, tail: i64, head_start: i64, wire: i64, sent: i64,
    peer: u8[..TCP_PEER_BYTES]
}

// Server state the handlers receive. default<TcpControl>() is a valid idle value. The slots are
// fixed-size, so the control can be a global, and the write queues live in the shared chunk pool.
struct TcpControl {
    shutdown_requested: bool, running: bool, stopping: bool,
    limit: i64, max_queue: i64, high_water: i64, idle_ms: i64, connect_ms: i64, grace_ms: i64, poll_ms: i32,
    stats: TcpStats, slots: TcpSlot[TCP_MAX_CONNS]
}

// Shared storage for queued output. Chunks come from one pool, and a freed chunk goes on tcp_free. The
// pool holds at most tcp_chunk_limit chunks, which covers every slot at its queue limit.
var tcp_chunks: u8[>..] = [];
var tcp_next: i64[>..] = [];
var tcp_free: i64[>..<] = [];
var tcp_chunk_limit: i64 = 0;
// The shared receive buffer. Data views point into it and are valid only during their event.
var tcp_read: u8[>..] = [];
// Readiness of each token in the current loop pass, written from gw_tcp_wait.
var tcp_ready: i32[TCP_TOKENS] = [0; TCP_TOKENS];

fn tcp_config() -> TcpConfig {
    return TcpConfig { port: TCP_DEFAULT_PORT, public_bind: TCP_DEFAULT_PUBLIC_BIND, max_conns: TCP_DEFAULT_MAX_CONNS,
        read_buffer_bytes: TCP_DEFAULT_READ_BUFFER_BYTES, max_write_queue_bytes: TCP_DEFAULT_MAX_WRITE_QUEUE_BYTES,
        idle_timeout_ms: TCP_DEFAULT_IDLE_TIMEOUT_MS, connect_timeout_ms: TCP_DEFAULT_CONNECT_TIMEOUT_MS,
        shutdown_grace_ms: TCP_DEFAULT_SHUTDOWN_GRACE_MS, poll_timeout_ms: TCP_DEFAULT_POLL_TIMEOUT_MS,
        handle_signals: TCP_DEFAULT_HANDLE_SIGNALS };
}

fn tcp_config_valid(c: TcpConfig) -> bool {
    return c.port >= MIN_PORT && c.port <= MAX_PORT && c.max_conns >= 1 && c.max_conns <= TCP_MAX_CONNS &&
        c.read_buffer_bytes >= 1 && c.read_buffer_bytes <= TCP_MAX_READ_BUFFER_BYTES &&
        c.max_write_queue_bytes >= TCP_CHUNK_BYTES && c.max_write_queue_bytes <= TCP_MAX_WRITE_QUEUE_BYTES &&
        c.idle_timeout_ms >= 0 && c.idle_timeout_ms <= TCP_MAX_TIMEOUT_MS &&
        c.connect_timeout_ms >= 1 && c.connect_timeout_ms <= TCP_MAX_TIMEOUT_MS &&
        c.shutdown_grace_ms >= 0 && c.shutdown_grace_ms <= TCP_MAX_TIMEOUT_MS &&
        c.poll_timeout_ms >= 1 && c.poll_timeout_ms <= TCP_MAX_POLL_TIMEOUT_MS;
}

// Requests a graceful stop: no new connections, queued output is flushed, then the loop returns.
fn tcp_request_shutdown(control: TcpControl&) { control.shutdown_requested = true; }

// The slot a connection id names, or -1 when the id is stale or unknown.
fn tcp_slot_of(control: TcpControl&, conn: i64) -> i64 {
    if conn <= 0 { return -1; }
    let slot = conn % TCP_SLOT_SPAN;
    let s .= control.slots[slot];
    if s.state == TCP_SLOT_FREE || s.gen != conn / TCP_SLOT_SPAN { return -1; }
    return slot;
}

fn tcp_chunks_available() -> i64 { return tcp_free.len + tcp_chunk_limit - tcp_next.len; }

fn tcp_take_chunk() -> i64 {
    if tcp_free.len > 0 { return tcp_free.pop(); }
    // Grow only: a resize could shrink, which the checker must treat as freeing views of the pool.
    let id = tcp_next.len;
    tcp_next.push(TCP_NO_CHUNK);
    for k in TCP_CHUNK_BYTES { tcp_chunks.push(0); }
    return id;
}

// Returns the whole chain to the pool. The queue is empty afterwards: wire equals sent.
fn tcp_release(s: TcpSlot&) {
    while s.head != TCP_NO_CHUNK {
        let next = tcp_next[s.head];
        tcp_free.push(s.head);
        s.head = next;
    }
    s.tail = TCP_NO_CHUNK;
    s.head_start = s.wire;
    s.sent = s.wire;
}

// Appends bytes after the last queued byte. The caller checked the queue limit and pool room.
fn tcp_append(s: TcpSlot&, bytes: const u8[:]) {
    if s.head == TCP_NO_CHUNK { s.head_start = s.wire; s.sent = s.wire; }
    var pos: i64 = 0;
    while pos < bytes.len {
        if (s.wire - s.head_start) % TCP_CHUNK_BYTES == 0 {
            let id = tcp_take_chunk();
            tcp_next[id] = TCP_NO_CHUNK;
            if s.tail == TCP_NO_CHUNK { s.head = id; } else { tcp_next[s.tail] = id; }
            s.tail = id;
        }
        let offset = (s.wire - s.head_start) % TCP_CHUNK_BYTES;
        let room = TCP_CHUNK_BYTES - offset;
        let left = bytes.len - pos;
        let n = if left < room { left } else { room };
        for k in n { tcp_chunks[s.tail * TCP_CHUNK_BYTES + offset + k] = bytes[pos + k]; }
        pos += n;
        s.wire += n;
    }
}

// Clears a slot for a new connection. The generation is kept: it changes on each allocation.
fn tcp_init_slot(s: TcpSlot&, fd: i32, state: i64, interest: i64, deadline: i64) {
    s.gen += 1;
    s.state = state;
    s.fd = fd;
    s.interest = interest;
    s.tag = 0;
    s.deadline = deadline;
    s.reason = 0;
    s.paused = false;
    s.full = false;
    s.app_paused = false;
    s.head = TCP_NO_CHUNK;
    s.tail = TCP_NO_CHUNK;
    s.head_start = 0;
    s.wire = 0;
    s.sent = 0;
    s.peer.clear();
}

fn tcp_now_plus(ms: i64) -> i64 { return clock_ns() + ms * NANOSECONDS_PER_MILLISECOND; }

// An open connection's idle deadline, or none when the idle timeout is off.
fn tcp_idle_deadline(control: TcpControl&) -> i64 {
    if control.idle_ms > 0 { return tcp_now_plus(control.idle_ms); }
    return TCP_NO_DEADLINE;
}

// Queues bytes for a connection. False, taking nothing, when the connection is not open or the
// bytes would exceed max_write_queue_bytes: the caller may then close it. Reads pause at the high-water mark.
fn tcp_send(control: TcpControl&, conn: i64, bytes: const u8[:]) -> bool {
    let slot = tcp_slot_of(control, conn);
    if slot < 0 { return false; }
    let s .= control.slots[slot];
    if s.state != TCP_SLOT_OPEN { return false; }
    let queued = s.wire - s.sent;
    let needed = (bytes.len + TCP_CHUNK_BYTES - 1) / TCP_CHUNK_BYTES + 1;
    if queued + bytes.len > control.max_queue || needed > tcp_chunks_available() {
        control.stats.refused_sends += 1;
        return false;
    }
    tcp_append(s, bytes);
    if s.wire - s.sent >= control.high_water {
        s.paused = true;
        s.full = true;
    }
    return true;
}

// Stops or resumes reading from a connection. A handler uses this for backpressure: a proxy stops
// reading from its client while the upstream queue is full. Reads also stop by themselves at high
// water, so the flag is only the handler's own. False for an unknown or stale connection.
fn tcp_pause_reads(control: TcpControl&, conn: i64, paused: bool) -> bool {
    let slot = tcp_slot_of(control, conn);
    if slot < 0 { return false; }
    control.slots[slot].app_paused = paused;
    return true;
}

// Queued bytes at which a connection stops reading and reports Writable once drained below.
fn tcp_high_water(control: TcpControl&) -> i64 { return control.high_water; }

// The connection id of an active slot, or 0 when the slot is free. Walk slots 0 .. max_conns-1 to
// reach every connection, e.g. to broadcast to all but one.
fn tcp_conn_at(control: TcpControl&, slot: i64) -> i64 {
    if slot < 0 || slot >= control.limit { return TCP_NO_CONN; }
    let s .= control.slots[slot];
    if s.state == TCP_SLOT_FREE { return TCP_NO_CONN; }
    return s.gen * TCP_SLOT_SPAN + slot;
}

// Sends the same bytes to every open connection that has room. Returns how many accepted them.
fn tcp_broadcast(control: TcpControl&, bytes: const u8[:]) -> i64 {
    var accepted: i64 = 0;
    for i in control.limit {
        let s .= control.slots[i];
        if s.state != TCP_SLOT_OPEN { continue; }
        if tcp_send(control, s.gen * TCP_SLOT_SPAN + i, bytes) { accepted += 1; }
    }
    return accepted;
}

// Marks a connection to close once its queued output is sent or the shutdown grace ends.
// The Closed event follows the actual close. False for an unknown or stale connection.
fn tcp_close(control: TcpControl&, conn: i64) -> bool {
    let slot = tcp_slot_of(control, conn);
    if slot < 0 { return false; }
    let s .= control.slots[slot];
    if s.state == TCP_SLOT_CLOSING || s.state == TCP_SLOT_LINGER { return true; }
    s.state = TCP_SLOT_CLOSING;
    s.reason = TCP_CLOSE_APP;
    s.deadline = tcp_now_plus(control.grace_ms);
    return true;
}

// Bytes queued but not yet sent on this connection (0 when unknown).
fn tcp_queued(control: TcpControl&, conn: i64) -> i64 {
    let slot = tcp_slot_of(control, conn);
    if slot < 0 { return 0; }
    let s .= control.slots[slot];
    return s.wire - s.sent;
}

// The peer's numeric address, valid while the connection lives ("" when unknown).
fn tcp_peer(control: TcpControl&, conn: i64) -> const u8[:] {
    let slot = tcp_slot_of(control, conn);
    if slot < 0 { return ""; }
    let s .= control.slots[slot];
    return s.peer[..];
}

// Application state per connection. The tag is set to 0 when a connection opens. Keep larger state in
// tables indexed by tcp_slot_of(control, conn); the slot is stable for the connection's life.
fn tcp_set_tag(control: TcpControl&, conn: i64, value: i64) -> bool {
    let slot = tcp_slot_of(control, conn);
    if slot < 0 { return false; }
    control.slots[slot].tag = value;
    return true;
}

fn tcp_tag(control: TcpControl&, conn: i64) -> i64 {
    let slot = tcp_slot_of(control, conn);
    if slot < 0 { return 0; }
    return control.slots[slot].tag;
}

// Starts a nonblocking connect to a numeric IPv4 or IPv6 address (names are not resolved). Returns the
// connection id, or 0 when the server is not running, no slot is free, or the address is refused at once.
// Open follows on success; Closed (CONNECT_FAILED or CONNECT_TIMEOUT) follows a failure.
fn tcp_connect(control: TcpControl&, host: const u8[:], port: i32) -> i64 {
    if !control.running || control.stopping { return 0; }
    var slot: i64 = -1;
    for i in control.limit {
        if control.slots[i].state == TCP_SLOT_FREE { slot = i; break; }
    }
    if slot < 0 { return 0; }
    let fd = tcp_connect_begin(host, port);
    if fd < 0 { return 0; }
    if tcp_register((slot + 1) as i32, fd, TCP_INTEREST_WRITE) < 0 {
        tcp_close_fd(fd);
        return 0;
    }
    let s .= control.slots[slot];
    tcp_init_slot(s, fd, TCP_SLOT_CONNECTING, TCP_INTEREST_WRITE, tcp_now_plus(control.connect_ms));
    control.stats.active += 1;
    control.stats.connects += 1;
    return s.gen * TCP_SLOT_SPAN + slot;
}

// Serves the TCP loop on config.port. Handler is a named function of the form
// fn on_event(net: web::TcpControl&, ev: web::TcpEvent), and Tick runs once per pass of the loop.
// Returns false when the configuration is invalid or the listener cannot start. The loop runs in
// this process on the calling thread; handlers must not block.
fn tcp_serve<H, Tick>(config: TcpConfig, control: TcpControl&) -> bool {
    if !tcp_config_valid(config) || control.running { return false; }
    var listener = tcp_listen(config.port, if config.public_bind { 1 } else { 0 });
    if listener < 0 { return false; }
    if config.handle_signals && tcp_signals_begin() < 0 {
        tcp_close_fd(listener);
        return false;
    }
    return tcp_loop(config, control, listener, H, Tick);
}

// The readiness loop. Event handlers run here, in order, so a handler's calls to tcp_send and tcp_close
// take effect in the same pass; queued output is then flushed.
fn tcp_loop<H, Tick>(config: TcpConfig, control: TcpControl&, inherited: i32) -> bool {
    var listener = inherited;
    if tcp_reactor_open((config.max_conns + 1) as i32) < 0 ||
        tcp_register(TCP_LISTENER_TOKEN, listener, TCP_INTEREST_READ) < 0 {
        tcp_reactor_close();
        tcp_close_fd(listener);
        if config.handle_signals { tcp_signals_end(); }
        return false;
    }
    control.running = true;
    control.stopping = false;
    control.shutdown_requested = false;
    control.limit = config.max_conns;
    control.max_queue = config.max_write_queue_bytes;
    control.high_water = config.max_write_queue_bytes / 2;
    control.idle_ms = config.idle_timeout_ms;
    control.connect_ms = config.connect_timeout_ms;
    control.grace_ms = config.shutdown_grace_ms;
    control.poll_ms = config.poll_timeout_ms;
    control.stats = default<TcpStats>();
    for i in TCP_MAX_CONNS { control.slots[i].state = TCP_SLOT_FREE; }
    tcp_chunks.clear();
    tcp_next.clear();
    tcp_free.clear();
    tcp_chunk_limit = config.max_conns * ((config.max_write_queue_bytes + TCP_CHUNK_BYTES - 1) / TCP_CHUNK_BYTES + 1);
    tcp_read.clear();
    tcp_read.resize(config.read_buffer_bytes, 0);
    for t in TCP_TOKENS { tcp_ready[t] = 0; }
    var tokens: i32[TCP_TOKENS] = [0; TCP_TOKENS];
    var events: i32[TCP_TOKENS] = [0; TCP_TOKENS];
    var grace_deadline: i64 = 0;
    var success = true;

    fn emit(ev: TcpEvent) { H(control, ev); }

    // Frees a slot: the descriptor leaves the readiness instance before it closes, then Closed is emitted.
    fn close_slot(i: i64, reason: i64) {
        let s .= control.slots[i];
        if s.state == TCP_SLOT_FREE { return; }
        let conn = s.gen * TCP_SLOT_SPAN + i;
        tcp_unregister((i + 1) as i32, s.fd);
        tcp_close_fd(s.fd);
        tcp_ready[i + 1] = 0;
        tcp_release(s);
        s.state = TCP_SLOT_FREE;
        s.fd = -1;
        control.stats.active -= 1;
        control.stats.closed += 1;
        emit(TcpEvent.Closed { conn: conn, reason: reason });
    }

    // Ends a graceful close once the queue is empty: FIN is sent, then the slot lingers until the peer
    // closes, so input still in flight is discarded instead of reset. A failed half-close closes at once.
    fn finish_close(i: i64) {
        let s .= control.slots[i];
        if tcp_half_close(s.fd) != 0 {
            close_slot(i, s.reason);
            return;
        }
        s.state = TCP_SLOT_LINGER;
        s.deadline = tcp_now_plus(control.grace_ms);
    }

    // Starts a graceful close: an open connection flushes first, a connecting one closes at once.
    fn begin_close(i: i64, reason: i64) {
        let s .= control.slots[i];
        if s.state == TCP_SLOT_FREE || s.state == TCP_SLOT_CLOSING || s.state == TCP_SLOT_LINGER { return; }
        if s.state == TCP_SLOT_CONNECTING {
            close_slot(i, reason);
            return;
        }
        s.state = TCP_SLOT_CLOSING;
        s.reason = reason;
        s.deadline = tcp_now_plus(control.grace_ms);
        if s.wire == s.sent { finish_close(i); }
    }

    // Reads and discards input while lingering. End of input or an error closes the slot.
    fn service_linger(i: i64) {
        let s .= control.slots[i];
        let n = tcp_recv(s.fd, tcp_read[..]);
        if n == IO_WOULD_BLOCK { return; }
        if n <= 0 { close_slot(i, s.reason); }
    }

    // Keeps the kernel's interest in step with the slot: read while open and unpaused, write while bytes
    // are queued, write while connecting. Only changed interest reaches the kernel.
    fn sync_interest(i: i64) {
        let s .= control.slots[i];
        if s.state == TCP_SLOT_FREE { return; }
        var want: i64 = 0;
        if s.state == TCP_SLOT_CONNECTING { want = TCP_INTEREST_WRITE; }
        else if s.state == TCP_SLOT_LINGER { want = TCP_INTEREST_READ; }
        else {
            if s.state == TCP_SLOT_OPEN && !s.paused && !s.app_paused { want = want | TCP_INTEREST_READ; }
            if s.wire > s.sent { want = want | TCP_INTEREST_WRITE; }
        }
        if want != s.interest && tcp_set_interest((i + 1) as i32, s.fd, want as i32) == 0 {
            s.interest = want;
        }
    }

    // Sends queued bytes until the kernel would block. Resumes reads once the queue is below high water.
    fn service_write(i: i64) {
        let s .= control.slots[i];
        let before = s.sent;
        while s.sent < s.wire {
            let offset = s.sent - s.head_start;
            let left = s.wire - s.sent;
            let room = TCP_CHUNK_BYTES - offset;
            let want = if left < room { left } else { room };
            let base = s.head * TCP_CHUNK_BYTES + offset;
            let n = tcp_send_bytes(s.fd, tcp_chunks[base..base + want]);
            if n == IO_WOULD_BLOCK { break; }
            if n <= 0 {
                close_slot(i, TCP_CLOSE_ERROR);
                return;
            }
            s.sent += n;
            control.stats.bytes_written += n;
            if s.sent == s.wire {
                tcp_release(s);
            } else if s.sent - s.head_start == TCP_CHUNK_BYTES {
                let next = tcp_next[s.head];
                tcp_free.push(s.head);
                s.head = next;
                s.head_start += TCP_CHUNK_BYTES;
            }
        }
        if s.sent != before && s.state == TCP_SLOT_OPEN { s.deadline = tcp_idle_deadline(control); }
        if s.wire - s.sent < control.high_water {
            s.paused = false;
            if s.full {
                s.full = false;
                emit(TcpEvent.Writable { conn: s.gen * TCP_SLOT_SPAN + i });
            }
        }
    }

    // One receive into the shared buffer; each read is one Data event.
    fn service_read(i: i64) {
        let s .= control.slots[i];
        let n = tcp_recv(s.fd, tcp_read[..]);
        if n == IO_WOULD_BLOCK { return; }
        if n < 0 {
            close_slot(i, TCP_CLOSE_ERROR);
            return;
        }
        if n == 0 {
            begin_close(i, TCP_CLOSE_PEER);
            return;
        }
        control.stats.bytes_read += n;
        s.deadline = tcp_idle_deadline(control);
        let conn = s.gen * TCP_SLOT_SPAN + i;
        emit(TcpEvent.Data { conn: conn, bytes: tcp_read[0..n] });
    }

    // Completes a connect that became writable: Open on success, Closed on a socket error.
    fn service_connect(i: i64) {
        let s .= control.slots[i];
        if tcp_connect_result(s.fd) != 0 {
            close_slot(i, TCP_CLOSE_CONNECT_FAILED);
            return;
        }
        s.state = TCP_SLOT_OPEN;
        s.deadline = tcp_idle_deadline(control);
        emit(TcpEvent.Open { conn: s.gen * TCP_SLOT_SPAN + i });
    }

    // Takes every pending connection, up to the accept budget. Each one opens a slot, or is refused
    // when all slots are busy.
    fn accept_pending() {
        for attempt in TCP_ACCEPT_BUDGET {
            let fd = tcp_accept(listener);
            if fd < 0 { break; }
            control.stats.accepted += 1;
            var slot: i64 = -1;
            for i in control.limit {
                if control.slots[i].state == TCP_SLOT_FREE { slot = i; break; }
            }
            if slot < 0 {
                tcp_close_fd(fd);
                control.stats.rejected += 1;
                continue;
            }
            if tcp_register((slot + 1) as i32, fd, TCP_INTEREST_READ) < 0 {
                tcp_close_fd(fd);
                control.stats.rejected += 1;
                continue;
            }
            let s .= control.slots[slot];
            tcp_init_slot(s, fd, TCP_SLOT_OPEN, TCP_INTEREST_READ, tcp_idle_deadline(control));
            var text: u8[TCP_PEER_BYTES] = [0; TCP_PEER_BYTES];
            let n = tcp_peer_address(fd, text[..]);
            if n > 0 { s.peer.append(text[..n]); }
            control.stats.active += 1;
            emit(TcpEvent.Open { conn: s.gen * TCP_SLOT_SPAN + slot });
        }
    }

    loop {
        Tick();
        if config.handle_signals && tcp_signal_pending() != 0 { control.shutdown_requested = true; }
        if control.shutdown_requested && !control.stopping {
            control.stopping = true;
            tcp_unregister(TCP_LISTENER_TOKEN, listener);
            tcp_close_fd(listener);
            listener = -1;
            grace_deadline = tcp_now_plus(config.shutdown_grace_ms);
            for i in control.limit { begin_close(i, TCP_CLOSE_SHUTDOWN); }
        }
        if control.stopping && (control.stats.active == 0 || clock_ns() >= grace_deadline) {
            for i in control.limit { close_slot(i, TCP_CLOSE_SHUTDOWN); }
            break;
        }
        for i in control.limit { sync_interest(i); }
        // Wait no longer than the nearest deadline, the poll interval, or the shutdown grace end.
        var wait_ms: i64 = config.poll_timeout_ms;
        let poll_now = clock_ns();
        for i in control.limit {
            let s .= control.slots[i];
            if s.state != TCP_SLOT_FREE && s.deadline != TCP_NO_DEADLINE {
                let remaining = (s.deadline - poll_now) / NANOSECONDS_PER_MILLISECOND;
                if remaining < wait_ms { wait_ms = if remaining > 0 { remaining } else { 0 }; }
            }
        }
        if control.stopping {
            let remaining = (grace_deadline - poll_now) / NANOSECONDS_PER_MILLISECOND;
            if remaining < wait_ms { wait_ms = if remaining > 0 { remaining } else { 0 }; }
        }
        for t in TCP_TOKENS { tcp_ready[t] = 0; }
        let count = tcp_wait(tokens, events, wait_ms as i32);
        if count < 0 {
            success = false;
            break;
        }
        for e in count as i64 { tcp_ready[tokens[e] as i64] = events[e]; }
        if tcp_ready[TCP_LISTENER_TOKEN] != 0 && !control.stopping { accept_pending(); }
        let now = clock_ns();
        for i in control.limit {
            let s .= control.slots[i];
            if s.state == TCP_SLOT_FREE { continue; }
            if s.state == TCP_SLOT_CONNECTING {
                if now >= s.deadline {
                    close_slot(i, TCP_CLOSE_CONNECT_TIMEOUT);
                } else if tcp_ready[i + 1] != 0 {
                    service_connect(i);
                }
                continue;
            }
            if s.deadline != TCP_NO_DEADLINE && now >= s.deadline {
                if s.state == TCP_SLOT_OPEN {
                    control.stats.timeouts += 1;
                    close_slot(i, TCP_CLOSE_IDLE);
                } else {
                    close_slot(i, s.reason);
                }
                continue;
            }
            if tcp_ready[i + 1] < 0 {
                close_slot(i, TCP_CLOSE_ERROR);
                continue;
            }
            if s.state == TCP_SLOT_LINGER {
                if tcp_ready[i + 1] != 0 { service_linger(i); }
                continue;
            }
            if s.state == TCP_SLOT_OPEN && !s.paused && !s.app_paused && tcp_ready[i + 1] != 0 {
                service_read(i);
            }
            if control.slots[i].state == TCP_SLOT_FREE { continue; }
            if control.slots[i].wire > control.slots[i].sent { service_write(i); }
            if control.slots[i].state == TCP_SLOT_FREE { continue; }
            if control.slots[i].state == TCP_SLOT_CLOSING && control.slots[i].wire == control.slots[i].sent {
                finish_close(i);
            }
        }
    }
    // Teardown. A failed wait leaves connections open, so they close here with the error reason.
    for i in control.limit { close_slot(i, TCP_CLOSE_ERROR); }
    if listener >= 0 {
        tcp_unregister(TCP_LISTENER_TOKEN, listener);
        tcp_close_fd(listener);
    }
    tcp_reactor_close();
    control.running = false;
    control.stopping = false;
    if config.handle_signals { tcp_signals_end(); }
    return success;
}
