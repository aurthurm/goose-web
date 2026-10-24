import src.constants.tcp;
import std;
namespace web;

// Framing for TCP protocols. A TcpFrame is the per-connection accumulation buffer: its capacity is
// TCP_FRAME_CAPACITY and inline, so an application's table of them (indexed by tcp_slot_of) costs
// exactly that much per slot. Feed the Data bytes of each connection through one of the functions
// below; complete lines or frames are passed to the block as views valid only during that call.

struct TcpFrame { bytes: u8[..TCP_FRAME_CAPACITY] }

// Splits data into lines on '\n' (a trailing '\r' is dropped). A line longer than max_line bytes
// fails the feed: the buffer is cleared and false is returned, and the caller should close the
// connection. Bytes of an unfinished line wait in the frame for the next feed.
fn tcp_feed_lines<F>(frame: TcpFrame&, data: const u8[:], max_line: i64) -> bool {
    if max_line < 1 || max_line > TCP_FRAME_CAPACITY { return false; }
    var pos: i64 = 0;
    while pos < data.len {
        let hit = find(data[pos..], "\n");
        let stop = if hit < 0 { data.len } else { pos + hit };
        if frame.bytes.len + (stop - pos) > max_line {
            frame.bytes.clear();
            return false;
        }
        frame.bytes.append(data[pos..stop]);
        if hit < 0 { return true; }
        var line_end = frame.bytes.len;
        if line_end > 0 && frame.bytes[line_end - 1] == '\r' { line_end -= 1; }
        F(frame.bytes[..line_end]);
        frame.bytes.clear();
        pos = stop + 1;
    }
    return true;
}

// Splits data into frames: a big-endian length of header bytes (2 or 4), then that many payload bytes.
// Each complete payload goes to the block. A length above max_frame fails the feed (the buffer is
// cleared and false is returned). header + max_frame must fit TCP_FRAME_CAPACITY.
fn tcp_feed_frames<F>(frame: TcpFrame&, data: const u8[:], header: i64, max_frame: i64) -> bool {
    if (header != 2 && header != 4) || max_frame < 0 || header + max_frame > TCP_FRAME_CAPACITY { return false; }
    var pos: i64 = 0;
    while pos < data.len {
        // The header may complete here; its length is checked at once, before any payload arrives.
        if frame.bytes.len < header {
            let want = header - frame.bytes.len;
            let take = if want < data.len - pos { want } else { data.len - pos };
            frame.bytes.append(data[pos..pos + take]);
            pos += take;
            if frame.bytes.len < header { continue; }
        }
        var length: i64 = 0;
        for k in header { length = length * 256 + frame.bytes[k] as i64; }
        if length > max_frame {
            frame.bytes.clear();
            return false;
        }
        let total = header + length;
        let want = total - frame.bytes.len;
        let take = if want < data.len - pos { want } else { data.len - pos };
        frame.bytes.append(data[pos..pos + take]);
        pos += take;
        if frame.bytes.len == total {
            F(frame.bytes[header..total]);
            frame.bytes.clear();
        }
    }
    return true;
}

// Appends one frame (header and payload) to out, for sending with tcp_send.
fn tcp_encode_frame(out: u8[>..]&, payload: const u8[:], header: i64) {
    for k in header {
        let shift = (header - 1 - k) * 8;
        out.push(((payload.len >> shift) & 255) as u8);
    }
    out.append(payload);
}
