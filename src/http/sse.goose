import src.constants.limits;
import std;
namespace web;

// Server-sent event framing. Pure functions: the runtime stages their output as chunks.
// One SSE message is one HTTP chunk, so each chunk ends with a blank line of event text.

// A heartbeat is the comment ": ping" plus a blank line: 8 bytes, so its chunk size is 8.
const SSE_PING_CHUNK = "8\r\n: ping\n\n\r\n";
const SSE_LAST_CHUNK = "0\r\n\r\n";

// An event name is one `event:` field: no CR or LF, and at most MAX_SSE_EVENT_BYTES.
fn sse_event_valid(event: const u8[:]) -> bool {
    if event.len > MAX_SSE_EVENT_BYTES { return false; }
    for ch in event {
        if ch == '\n' || ch == '\r' { return false; }
    }
    return true;
}

fn sse_data_line(out: u8[>..]&, line: const u8[:]) {
    out.append("data: ");
    out.append(line);
    out.append("\n");
}

// Appends the event text for one message: an `event:` line when the name is not empty, then one
// `data:` line per line of data. CR, LF and CRLF all end a line, as the SSE format defines.
// Returns false, appending nothing, when the event name is invalid.
fn sse_format_message(out: u8[>..]&, event: const u8[:], data: const u8[:]) -> bool {
    if !sse_event_valid(event) { return false; }
    if event.len > 0 {
        out.append("event: ");
        out.append(event);
        out.append("\n");
    }
    var line: i64 = 0;
    var i: i64 = 0;
    while i < data.len {
        let ch = data[i];
        if ch == '\n' || ch == '\r' {
            sse_data_line(out, data[line..i]);
            if ch == '\r' && i + 1 < data.len && data[i + 1] == '\n' { i += 1; }
            line = i + 1;
        }
        i += 1;
    }
    sse_data_line(out, data[line..]);
    out.append("\n");
    return true;
}

// Writes n as lowercase hexadecimal, the chunk-size form of HTTP/1.1 framing.
fn sse_append_hex(out: u8[>..]&, n: i64) {
    var digits: u8[16] = [0; 16];
    var count: i64 = 0;
    var v = n;
    loop {
        let d = (v % 16) as u8;
        digits[count] = if d < 10 { '0' + d } else { 'a' + d - 10 };
        count += 1;
        v = v / 16;
        if v == 0 { break; }
    }
    while count > 0 {
        count -= 1;
        out.push(digits[count]);
    }
}

// Appends payload as one HTTP chunk: hex size, CRLF, payload, CRLF.
fn sse_frame(out: u8[>..]&, payload: const u8[:]) {
    sse_append_hex(out, payload.len);
    out.append("\r\n");
    out.append(payload);
    out.append("\r\n");
}

// The bytes that end a stream: the `event: close` message as one chunk, then the terminating chunk.
fn sse_close_chunks(out: u8[>..]&) {
    var message: u8[>..] = [];
    assert(sse_format_message(message, "close", ""));
    sse_frame(out, message[..]);
    out.append(SSE_LAST_CHUNK);
}
