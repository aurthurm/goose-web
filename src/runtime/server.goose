import src.constants.runtime;
import src.constants.http;
import src.http.request;
import src.http.response;
import std;
import os;
namespace web;

extern fn gw_listen_config(port: i32, public_bind: i32) -> i32;
extern fn gw_transport_max_clients() -> i64;
extern fn gw_signals_begin() -> i32;
extern fn gw_signal_pending() -> i32;
extern fn gw_signals_end();

struct ServerConfig {
    port: i32, public_bind: bool, max_clients: i64, max_request_bytes: i64,
    read_timeout_ms: i64, write_timeout_ms: i64, poll_timeout_ms: i32,
    shutdown_grace_ms: i64, max_requests: i64, handle_signals: bool
}
struct ServerStats {
    accepted: i64, active: i64, completed: i64, rejected: i64,
    timeouts: i64, forced_closes: i64, bytes_read: i64, bytes_written: i64
}
struct ServerControl {
    shutdown_requested: bool, running: bool, stopping: bool, stats: ServerStats
}
fn server_config() -> ServerConfig {
    return ServerConfig { port: DEFAULT_PORT, public_bind: DEFAULT_PUBLIC_BIND, max_clients: DEFAULT_MAX_CLIENTS,
        max_request_bytes: DEFAULT_MAX_REQUEST_BYTES, read_timeout_ms: DEFAULT_READ_TIMEOUT_MS, write_timeout_ms: DEFAULT_WRITE_TIMEOUT_MS,
        poll_timeout_ms: DEFAULT_POLL_TIMEOUT_MS, shutdown_grace_ms: DEFAULT_SHUTDOWN_GRACE_MS, max_requests: UNLIMITED_REQUESTS, handle_signals: DEFAULT_HANDLE_SIGNALS };
}
// Millisecond durations are capped at one day to keep nanosecond arithmetic safe.
fn validate_server_config(c: ServerConfig) -> bool {
    return c.port >= MIN_PORT && c.port <= MAX_PORT && c.max_clients >= 1 && c.max_clients <= MAX_CLIENTS &&
        c.max_request_bytes >= 1 && c.max_request_bytes <= MAX_REQUEST_BYTES && c.max_requests >= UNLIMITED_REQUESTS &&
        c.read_timeout_ms >= 1 && c.read_timeout_ms <= MAX_TIMEOUT_MS &&
        c.write_timeout_ms >= 1 && c.write_timeout_ms <= MAX_TIMEOUT_MS &&
        c.poll_timeout_ms >= 1 && c.poll_timeout_ms <= MAX_POLL_TIMEOUT_MS &&
        c.shutdown_grace_ms >= 0 && c.shutdown_grace_ms <= MAX_TIMEOUT_MS;
}
fn request_shutdown(control: ServerControl&) { control.shutdown_requested = true; }
extern fn gw_accept(listener: i32) -> i32;
extern fn gw_recv(fd: i32, buffer: u8[:]) -> i64;
extern fn gw_send(fd: i32, buffer: const u8[:]) -> i64;
extern fn gw_poll(fds: const i32[:], interests: const i32[:], ready: i32[:], timeout: i32) -> i32;
extern fn gw_close(fd: i32);

struct Connection {
    fd: i32, used: i64, sent: i64, writing: bool, deadline: i64,
    input: u8[MAX_REQUEST_BYTES], output: u8[..MAX_RESPONSE_WIRE_BYTES]
}

fn close_connection(c: Connection&, stats: ServerStats&) {
    if c.fd >= 0 { stats.active -= 1; }
    gw_close(c.fd);
    c.fd = INVALID_SOCKET;
    c.used = 0;
    c.sent = 0;
    c.writing = false;
    c.output.clear();
}

fn prepare_response(c: Connection&, r: Response&, head: bool, timeout_ms: i64) {
    var wire: u8[>..] = [];
    serialize_response(wire, r, head);
    c.output = wire;
    c.writing = true;
    c.deadline = clock_ns() + timeout_ms * NANOSECONDS_PER_MILLISECOND;
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
                control.stats.timeouts += 1;
                close_connection(c, control.stats);
                continue;
            }
            if ready[i + 1] < 0 { close_connection(c, control.stats); continue; }
            if ready[i + 1] == 0 { continue; }
            if c.writing {
                let n = gw_send(c.fd, c.output[c.sent..]);
                if n == IO_WOULD_BLOCK { continue; }
                if n <= 0 { close_connection(c, control.stats); continue; }
                c.sent += n;
                control.stats.bytes_written += n;
                if c.sent == c.output.len {
                    close_connection(c, control.stats);
                    control.stats.completed += 1;
                }
            } else {
                let n = gw_recv(c.fd, c.input[c.used..config.max_request_bytes]);
                if n == IO_WOULD_BLOCK { continue; }
                if n <= 0 { close_connection(c, control.stats); continue; }
                c.used += n;
                control.stats.bytes_read += n;
                let request, parsed_status = parse_request(c.input[..c.used]);
                var status = parsed_status;
                if status == PARSE_INCOMPLETE && c.used >= config.max_request_bytes {
                    status = if find(c.input[..c.used], "\r\n\r\n") < 0 { HTTP_REQUEST_HEADER_FIELDS_TOO_LARGE } else { HTTP_CONTENT_TOO_LARGE };
                }
                if status == PARSE_INCOMPLETE { continue; }
                var r = response();
                if status == HTTP_OK { H(request, r); }
                else { r.status = status; r.body = reason(status); }
                prepare_response(c, r, status == HTTP_OK && request.method == METHOD_HEAD, config.write_timeout_ms);
            }
        }
    }
    if !control.stopping {
        control.stopping = true;
        Lifecycle(SERVER_STOPPING, control.stats);
    }
    for i in clients.len {
        if clients[i].fd >= 0 { control.stats.forced_closes += 1; }
        close_connection(clients[i], control.stats);
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
