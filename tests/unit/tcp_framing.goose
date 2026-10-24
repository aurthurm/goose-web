// Import only the public package, just as an application does.
import goose_web from "../..";
import std;

// Line and length-prefixed framing: boundaries split across feeds, CR handling, limits and encoding.
fn test_lines() {
    var frame: web::TcpFrame = default<web::TcpFrame>();
    var seen: u8[>..] = [];
    var count = 0;
    let a = web::tcp_feed_lines(frame, "one\ntw", 16) { line => { format(seen, "[", line, "]"); count += 1; } };
    assert(a && count == 1 && seen == "[one]");
    let b = web::tcp_feed_lines(frame, "o\r\nthree\n\n", 16) { line => { format(seen, "[", line, "]"); count += 1; } };
    assert(b && count == 4 && seen == "[one][two][three][]");
    // An unfinished line waits in the frame; it fails once it outgrows max_line.
    let c = web::tcp_feed_lines(frame, "0123456789", 16) { line => { count += 100; } };
    assert(c && count == 4 && frame.bytes.len == 10);
    let d = web::tcp_feed_lines(frame, "0123456789", 16) { line => { count += 100; } };
    assert(!d && frame.bytes.len == 0 && count == 4);
    // Lines of exactly max_line bytes are accepted.
    let e = web::tcp_feed_lines(frame, "abcdefghijklmnop\n", 16) { line => { count += 1; } };
    assert(e && count == 5);
}

fn test_frames() {
    var frame: web::TcpFrame = default<web::TcpFrame>();
    var seen: u8[>..] = [];
    var wire: u8[>..] = [];
    web::tcp_encode_frame(wire, "hi", 2);
    web::tcp_encode_frame(wire, "", 2);
    web::tcp_encode_frame(wire, "four", 2);
    assert(wire.len == 4 + 2 + 6 && wire[0] == 0 && wire[1] == 2 && wire[2] == 'h' && wire[3] == 'i');
    assert(wire[4] == 0 && wire[5] == 0 && wire[6] == 0 && wire[7] == 4 && wire[8] == 'f');
    // Feed the stream one byte at a time: each frame still arrives whole.
    var frames_seen = 0;
    for i in wire.len {
        let ok = web::tcp_feed_frames(frame, wire[i..i + 1], 2, 100) { payload => {
            format(seen, "<", payload, ">");
            frames_seen += 1;
        } };
        assert(ok);
    }
    assert(frames_seen == 3 && seen == "<hi><><four>");
    // A four-byte header carries a longer frame; a length above max_frame fails the feed.
    var big: u8[>..] = [];
    web::tcp_encode_frame(big, "abc", 4);
    assert(big.len == 7 && big[3] == 3);
    let ok = web::tcp_feed_frames(frame, big[..], 4, 100) { payload => { frames_seen += 1; } };
    assert(ok && frames_seen == 4);
    // Length 256 with a two-byte header (0x01 0x00) is over max_frame 100: refused, nothing delivered.
    var over: u8[>..] = [1, 0];
    let refused = web::tcp_feed_frames(frame, over[..], 2, 100) { payload => { frames_seen += 100; } };
    assert(!refused && frame.bytes.len == 0 && frames_seen == 4);
    // Invalid headers and sizes are refused before any byte is read.
    assert(!web::tcp_feed_frames(frame, "xy", 3, 10) { payload => { frames_seen += 100; } });
    assert(!web::tcp_feed_frames(frame, "xy", 2, web::TCP_FRAME_CAPACITY) { payload => { frames_seen += 100; } });
}

fn main() {
    test_lines();
    test_frames();
    print("tcp framing unit tests passed");
}
