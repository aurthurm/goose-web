import goose_web from "../..";
import std;
import os;

// A line-based chat room over TCP. Each line is one message to the other members. Commands:
// /nick NAME (up to 15 bytes) and /quit. Lines longer than 511 bytes close the connection.
// Usage: server [port]
const MAX_MEMBERS = 64;
const NAME_BYTES = 15;
const LINE_BYTES = 511;

var control = default<web::TcpControl>();
// One line accumulator and one display name per connection slot.
var frames: web::TcpFrame[MAX_MEMBERS];
var names: u8[..16][MAX_MEMBERS];

fn tick() {}

// Sends text to every member except `except`. A member whose queue refuses the text is disconnected.
fn broadcast(net: web::TcpControl&, except: i64, text: const u8[:]) {
    for slot in MAX_MEMBERS {
        let conn = web::tcp_conn_at(net, slot);
        if conn == web::TCP_NO_CONN || conn == except { continue; }
        if !web::tcp_send(net, conn, text) { web::tcp_close(net, conn); }
    }
}

fn handle_line(net: web::TcpControl&, conn: i64, line: const u8[:]) {
    let slot = web::tcp_slot_of(net, conn);
    if line == "/quit" {
        web::tcp_close(net, conn);
        return;
    }
    if line.len > 6 && line[..6] == "/nick " {
        let wanted = line[6..];
        let length = if wanted.len > NAME_BYTES { NAME_BYTES } else { wanted.len };
        names[slot].clear();
        names[slot].append(wanted[..length]);
        return;
    }
    let message = str(names[slot], ": ", line, "\n");
    broadcast(net, conn, message[..]);
}

fn on_event(net: web::TcpControl&, ev: web::TcpEvent) {
    match ev {
        Open o => {
            let slot = web::tcp_slot_of(net, o.conn);
            names[slot].clear();
            format(names[slot], "guest", slot);
            web::tcp_send(net, o.conn, "Welcome. /nick NAME to rename, /quit to leave.\n");
            let joined = str("* ", names[slot], " joined\n");
            broadcast(net, o.conn, joined[..]);
        },
        Data d => {
            let slot = web::tcp_slot_of(net, d.conn);
            let fine = web::tcp_feed_lines(frames[slot], d.bytes, LINE_BYTES) { line => handle_line(net, d.conn, line); };
            if !fine {
                web::tcp_send(net, d.conn, "line too long\n");
                web::tcp_close(net, d.conn);
            }
        },
        Closed c => {
            let slot = c.conn % web::TCP_SLOT_SPAN;
            let left = str("* ", names[slot], " left\n");
            broadcast(net, web::TCP_NO_CONN, left[..]);
            frames[slot].bytes.clear();
        },
        _ => {},
    }
}

fn main() {
    let argv = args();
    var config = web::tcp_config();
    config.handle_signals = true;
    config.max_conns = MAX_MEMBERS;
    if argv.len > 1 {
        let port, ok = parse_int(argv[1]);
        if !ok { abort("port must be a number"); }
        config.port = port as i32;
    }
    print("tcp chat listening on port ", config.port);
    let started = web::tcp_serve(config, control, on_event, tick);
    if !started { abort("tcp server failed to start"); }
}
