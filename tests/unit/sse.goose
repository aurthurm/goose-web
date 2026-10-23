// Import only the public package, just as an application does.
import goose_web from "../..";
import std;

// Event text and chunk framing, checked against the SSE wire format byte for byte.
fn test_event_names() {
    assert(web::sse_event_valid(""));
    assert(web::sse_event_valid("tick"));
    assert(!web::sse_event_valid("bad\nname"));
    assert(!web::sse_event_valid("bad\rname"));
    var long_name: u8[>..] = [];
    long_name.resize(web::MAX_SSE_EVENT_BYTES + 1, 'e');
    assert(!web::sse_event_valid(long_name[..]));
}

fn test_message_text() {
    var out: u8[>..] = [];
    assert(web::sse_format_message(out, "tick", "1"));
    assert(out[..] == "event: tick\ndata: 1\n\n");
    out.clear();
    assert(web::sse_format_message(out, "", "a\nb"));
    assert(out[..] == "data: a\ndata: b\n\n");
    // CR, LF and CRLF each end a data line.
    out.clear();
    assert(web::sse_format_message(out, "", "a\r\nb\rc"));
    assert(out[..] == "data: a\ndata: b\ndata: c\n\n");
    // Empty data is one empty data line; a trailing line break leaves an empty last line.
    out.clear();
    assert(web::sse_format_message(out, "", ""));
    assert(out[..] == "data: \n\n");
    out.clear();
    assert(web::sse_format_message(out, "", "x\n"));
    assert(out[..] == "data: x\ndata: \n\n");
    // An invalid name is refused and appends nothing.
    out.clear();
    assert(!web::sse_format_message(out, "bad\nname", "x"));
    assert(out.len == 0);
}

fn test_chunk_framing() {
    var out: u8[>..] = [];
    web::sse_frame(out, "hello");
    assert(out[..] == "5\r\nhello\r\n");
    out.clear();
    var sixteen: u8[>..] = [];
    sixteen.resize(16, 'x');
    web::sse_frame(out, sixteen[..]);
    assert(find(out, "10\r\n") == 0 && out.len == 4 + 16 + 2);
    out.clear();
    var big: u8[>..] = [];
    big.resize(255, 'y');
    web::sse_frame(out, big[..]);
    assert(find(out, "ff\r\n") == 0);
    // The heartbeat constant is exactly one frame of its comment.
    var ping: u8[>..] = [];
    web::sse_frame(ping, ": ping\n\n");
    assert(ping[..] == web::SSE_PING_CHUNK);
    // The close message and the terminating chunk: 21 bytes of event text.
    var closing: u8[>..] = [];
    web::sse_close_chunks(closing);
    assert(closing[..] == "15\r\nevent: close\ndata: \n\n\r\n0\r\n\r\n");
}

// The stream head is chunked and has no Content-Length.
fn test_stream_head() {
    var r = web::response();
    r.content_type = web::CONTENT_TYPE_EVENT_STREAM;
    assert(web::set_header(r, "X-Stream", "1"));
    var wire: u8[>..] = [];
    web::serialize_stream_head(wire, r);
    assert(find(wire, "HTTP/1.1 200 OK\r\n") == 0);
    assert(find(wire, "Content-Type: text/event-stream\r\n") >= 0);
    assert(find(wire, "Cache-Control: no-cache\r\n") >= 0);
    assert(find(wire, "Transfer-Encoding: chunked\r\n") >= 0);
    assert(find(wire, "X-Stream: 1\r\n") >= 0);
    assert(find(wire, "Content-Length") < 0);
    assert(wire[wire.len - 4..] == "\r\n\r\n");
}

// Publishing stages frames in the outbox and counts subscribers on the channel.
fn test_publish() {
    var control = default<web::ServerControl>();
    web::sse_outbox.clear();
    control.sse_limit = web::DEFAULT_SSE_MAX_QUEUED_BYTES;
    assert(web::sse_publish(control, 1, "tick", "x") == 0);
    control.running = true;
    assert(web::sse_publish(control, 1, "tick", "x") == 0);
    control.sse_slots[0] = web::SseSlot { active: true, channel: 1 };
    control.sse_slots[1] = web::SseSlot { active: true, channel: 2 };
    assert(web::sse_publish(control, 1, "tick", "x") == 1);
    assert(web::sse_publish(control, 3, "tick", "x") == 0);
    assert(web::sse_publish(control, 1, "bad\nname", "x") == -1);
    assert(control.sse_msg_count == 1 && control.sse_msg_channel[0] == 1);
    assert(web::sse_outbox[..] == "15\r\nevent: tick\ndata: x\n\n\r\n");
    assert(control.sse_msg_end[0] == web::sse_outbox.len);
    assert(web::sse_publish(control, 2, "", "y") == 1);
    assert(control.sse_msg_count == 2 && control.sse_msg_channel[1] == 2);
    // A message over the per-stream limit is refused, and so is one over MAX_SSE_MESSAGE_BYTES.
    control.sse_limit = 16;
    assert(web::sse_publish(control, 1, "tick", "x") == -1);
    control.sse_limit = web::DEFAULT_SSE_MAX_QUEUED_BYTES;
    var huge: u8[>..] = [];
    huge.resize(web::MAX_SSE_MESSAGE_BYTES + 1, 'h');
    assert(web::sse_publish(control, 1, "", huge[..]) == -1);
    // A full outbox refuses rather than grows.
    while control.sse_msg_count < web::MAX_SSE_OUTBOX_MESSAGES {
        assert(web::sse_publish(control, 1, "", "z") == 1);
    }
    assert(web::sse_publish(control, 1, "", "z") == -1);
    control.stopping = true;
    assert(web::sse_publish(control, 1, "", "z") == 0);
}

// Reads a stream's unsent chain back as wire bytes.
fn chain_bytes(pool: web::ChunkPool&, c: web::Connection&, out: u8[>..]&) {
    var id = c.head;
    var pos: i64 = 0;
    let total = c.wire_len - c.head_start;
    while pos < total {
        let n = if total - pos < web::RESPONSE_CHUNK_BYTES { total - pos } else { web::RESPONSE_CHUNK_BYTES };
        for i in n { out.push(pool.bytes[id * web::RESPONSE_CHUNK_BYTES + i]); }
        pos += n;
        id = pool.next[id];
    }
}

// Stream chains append across chunk boundaries and refuse whole when limits or the pool would be passed.
fn test_stream_queue() {
    var pool = web::ChunkPool { count: 0, free_count: 0, max_chunks: 3, free: [0; web::MAX_POOL_CHUNKS],
        next: [0; web::MAX_POOL_CHUNKS], bytes: [] };
    var c = default<web::Connection>();
    var expected: u8[>..] = [];
    var first: u8[>..] = [];
    for i in 20000 { first.push((i % 251) as! u8); }
    assert(web::sse_queue(c, pool, first[..], 1 << 20));
    expected.append(first[..]);
    // The tail fits in the second chunk's free space, so no chunk is taken.
    let count_before = pool.count;
    assert(web::sse_queue(c, pool, "tail-bytes", 1 << 20));
    expected.append("tail-bytes");
    assert(pool.count == count_before && c.writing);
    var got: u8[>..] = [];
    chain_bytes(pool, c, got);
    assert(got[..] == expected[..]);
    // Unsent bytes count against the limit: nothing changes when the limit would pass.
    let before = c.wire_len;
    assert(!web::sse_queue(c, pool, "0123456789", c.wire_len - c.sent + 9));
    assert(c.wire_len == before);
    // Running out of pool chunks is refused whole, with no partial write.
    var more: u8[>..] = [];
    more.resize(web::RESPONSE_CHUNK_BYTES * 2, 'm');
    assert(!web::sse_queue(c, pool, more[..], 1 << 20));
    assert(c.wire_len == before);
    got.clear();
    chain_bytes(pool, c, got);
    assert(got[..] == expected[..]);
}

fn main() {
    test_event_names();
    test_message_text();
    test_chunk_framing();
    test_stream_head();
    test_publish();
    test_stream_queue();
}
