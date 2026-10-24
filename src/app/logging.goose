import src.constants.http;
import src.constants.limits;
import src.http.request;
import src.http.response;
import src.http.headers;
import src.app.context;
import src.app.proxy;
import src.sys.process;
import json;
import std;
namespace web;

// Structured request log: json_logger prints one JSON object per request, after the inner chain has run.
// The line is built by json_log_line, which takes no clock or socket input, so tests check its shape directly.
// See docs/api.md#structured-logs.

const LOG_USER_AGENT_MAX_BYTES = 128;
const LOG_TEXT_MAX_BYTES = 2048;
const SECONDS_PER_DAY = 86400;
const NANOSECONDS_PER_MICROSECOND = 1000;

// Everything one log line reports. Text fields are copied byte by byte through log_safe_text. pid 0 omits the field.
struct LogEntry {
    unix_seconds: i64, request_id: i64, method: const u8[:], path: const u8[:], route: const u8[:],
    status: i32, bytes: i64, duration_us: i64, peer: const u8[:], client_ip: const u8[:],
    user_agent: const u8[:], pid: i32
}

// Writes text as JSON-safe ASCII: bytes outside 32-126 become '?', then the JSON encoder escapes " and \.
// So the line stays valid JSON whatever the client sent, and a crafted target cannot split it.
fn log_safe_text(out: u8[>..]&, text: const u8[:], max_bytes: i64) {
    var copied: i64 = 0;
    var safe: u8[>..] = [];
    for ch in text {
        if copied == max_bytes { break; }
        if ch < 32 || ch > 126 { safe.push('?'); } else { safe.push(ch); }
        copied += 1;
    }
    json::format_string(out, safe[..]);
}

// Writes value as exactly width decimal digits, zero padded (width at most 9).
fn log_digits(out: u8[>..]&, value: i64, width: i64) {
    var divisor: i64 = 1;
    for i in width - 1 { divisor *= 10; }
    for i in width {
        let digit = (value / divisor) % 10;
        out.push((48 + digit) as u8);
        divisor /= 10;
    }
}

// RFC 3339 UTC timestamp ("2026-10-24T10:00:00Z") for unix seconds, using the proleptic Gregorian calendar
// (days from civil, Howard Hinnant's algorithm). Negative inputs are clamped to the epoch.
fn log_timestamp(out: u8[>..]&, unix_seconds: i64) {
    let secs = if unix_seconds < 0 { 0 } else { unix_seconds };
    let days = secs / SECONDS_PER_DAY;
    let day_seconds = secs % SECONDS_PER_DAY;
    let z = days + 719468;
    let era = (if z >= 0 { z } else { z - 146096 }) / 146097;
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = yoe + era * 400 + (if month <= 2 { 1 } else { 0 });
    log_digits(out, year, 4);
    out.push('-');
    log_digits(out, month, 2);
    out.push('-');
    log_digits(out, day, 2);
    out.push('T');
    log_digits(out, day_seconds / 3600, 2);
    out.push(':');
    log_digits(out, (day_seconds / 60) % 60, 2);
    out.push(':');
    log_digits(out, day_seconds % 60, 2);
    out.push('Z');
}

// Level by status: 5xx is error, 4xx is warn, everything else info.
fn log_level(status: i32) -> const u8[:] {
    if status >= 500 { return "error"; }
    if status >= 400 { return "warn"; }
    return "info";
}

// One log line as a JSON object, without the newline. Keys: ts, level, request_id, method, path, route, status,
// bytes, duration_us, peer, client_ip, user_agent and pid (only for worker processes). route is null when no
// route matched. Field values are JSON-safe (log_safe_text).
fn json_log_line(out: u8[>..]&, e: LogEntry) {
    out.append("{\"ts\":\"");
    log_timestamp(out, e.unix_seconds);
    out.append("\",\"level\":\"");
    out.append(log_level(e.status));
    format(out, "\",\"request_id\":", e.request_id, ",\"method\":");
    log_safe_text(out, e.method, LOG_TEXT_MAX_BYTES);
    out.append(",\"path\":");
    log_safe_text(out, e.path, LOG_TEXT_MAX_BYTES);
    out.append(",\"route\":");
    if e.route.len == 0 { out.append("null"); } else { log_safe_text(out, e.route, LOG_TEXT_MAX_BYTES); }
    format(out, ",\"status\":", e.status, ",\"bytes\":", e.bytes, ",\"duration_us\":", e.duration_us);
    out.append(",\"peer\":");
    log_safe_text(out, e.peer, LOG_TEXT_MAX_BYTES);
    out.append(",\"client_ip\":");
    log_safe_text(out, e.client_ip, LOG_TEXT_MAX_BYTES);
    out.append(",\"user_agent\":");
    log_safe_text(out, e.user_agent, LOG_USER_AGENT_MAX_BYTES);
    if e.pid != 0 { format(out, ",\"pid\":", e.pid); }
    out.append("}");
}

// Prints one JSON line after Next, with the status, bytes and duration of the response.
// include_query: log the full target (path and query string) instead of the path alone. Queries may carry
// secrets, so the default is off. route is the matched route pattern (e.g. /users/:id), or null.
fn json_logger<Next>(c: Ctx&, include_query: bool = false) {
    let started = clock_ns();
    Next();
    let elapsed_ns = clock_ns() - started;
    var line: u8[>..] = [];
    json_log_line(line, LogEntry {
        unix_seconds: unix_seconds(),
        request_id: c.request_id,
        method: c.method(),
        path: if include_query { c.request.target } else { path(c) },
        route: route_pattern(c),
        status: c.response.status,
        bytes: body_len(c.response),
        duration_us: elapsed_ns / NANOSECONDS_PER_MICROSECOND,
        peer: peer(c),
        client_ip: client_ip(c),
        user_agent: header(c, "User-Agent"),
        pid: if worker_process { process_id() } else { 0 },
    });
    print(line);
}
