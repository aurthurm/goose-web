import goose_web from "../..";
import std;
import os;

// TCP test fixture for tests/integration/tcp.py. Usage:
//   tcp echo PORT [key=value ...]          echoes bytes back
//   tcp lines PORT [key=value ...]         echoes each line as "echo: LINE" (lines up to 64 bytes)
//   tcp frames PORT [key=value ...]        echoes 2-byte length-prefixed frames (payload up to 1000 bytes)
//   tcp dial LISTEN_PORT TARGET_PORT       connects to 127.0.0.1:TARGET_PORT, sends PING, prints the reply
// Options: idle (ms, 0 = off), queue (max write queue bytes), read (read buffer bytes), grace (ms),
// conns (max connections). The loop prints one STATS line when it stops, from SIGINT or SIGTERM.
const MODE_ECHO = 0;
const MODE_LINES = 1;
const MODE_FRAMES = 2;
const MODE_DIAL = 3;

var control = default<web::TcpControl>();
var frames: web::TcpFrame[64];
var mode_code: i64 = MODE_ECHO;
var dial_port: i32 = 0;
var dialed = false;
var dialed_conn: i64 = 0;

fn tick() {
    if mode_code == MODE_DIAL && !dialed {
        dialed = true;
        dialed_conn = web::tcp_connect(control, "127.0.0.1", dial_port);
        if dialed_conn == web::TCP_NO_CONN {
            print("dial refused at once");
            web::tcp_request_shutdown(control);
        }
    }
}

fn reply_line(net: web::TcpControl&, conn: i64, line: const u8[:]) {
    let reply = str("echo: ", line, "\n");
    if !web::tcp_send(net, conn, reply[..]) { web::tcp_close(net, conn); }
}

fn reply_frame(net: web::TcpControl&, conn: i64, payload: const u8[:]) {
    var out: u8[>..] = [];
    web::tcp_encode_frame(out, payload, 2);
    if !web::tcp_send(net, conn, out[..]) { web::tcp_close(net, conn); }
}

fn on_event(net: web::TcpControl&, ev: web::TcpEvent) {
    match ev {
        Open o => {
            if mode_code == MODE_DIAL { web::tcp_send(net, o.conn, "PING\n"); }
        },
        Data d => {
            let slot = web::tcp_slot_of(net, d.conn);
            if mode_code == MODE_LINES {
                let fine = web::tcp_feed_lines(frames[slot], d.bytes, 64) { line => reply_line(net, d.conn, line); };
                if !fine {
                    web::tcp_send(net, d.conn, "too long\n");
                    web::tcp_close(net, d.conn);
                }
            } else if mode_code == MODE_FRAMES {
                let fine = web::tcp_feed_frames(frames[slot], d.bytes, 2, 1000) { payload => reply_frame(net, d.conn, payload); };
                if !fine { web::tcp_close(net, d.conn); }
            } else if mode_code == MODE_DIAL {
                print("reply: ", d.bytes);
                web::tcp_close(net, d.conn);
            } else {
                if !web::tcp_send(net, d.conn, d.bytes) { web::tcp_close(net, d.conn); }
            }
        },
        Closed c => {
            if mode_code == MODE_DIAL {
                print("closed: ", c.reason);
                web::tcp_request_shutdown(net);
            }
        },
        _ => {},
    }
}

fn option_value(argv: u8[:][:], name: const u8[:], fallback: i64) -> i64 {
    for arg in argv {
        let eq = find(arg, "=");
        if eq > 0 && arg[..eq] == name {
            let value, ok = parse_int(arg[eq + 1..]);
            if ok { return value; }
        }
    }
    return fallback;
}

fn main() {
    let argv = args();
    if argv.len < 3 { abort("usage: tcp MODE PORT [options]"); }
    var config = web::tcp_config();
    config.handle_signals = true;
    if argv[1] == "dial" {
        if argv.len < 4 { abort("usage: tcp dial LISTEN_PORT TARGET_PORT"); }
        mode_code = MODE_DIAL;
        let target, target_ok = parse_int(argv[3]);
        if !target_ok { abort("target port must be a number"); }
        dial_port = target as i32;
    } else if argv[1] == "lines" {
        mode_code = MODE_LINES;
    } else if argv[1] == "frames" {
        mode_code = MODE_FRAMES;
    } else if argv[1] != "echo" {
        abort("unknown mode");
    }
    let port, port_ok = parse_int(argv[2]);
    if !port_ok { abort("port must be a number"); }
    config.port = port as i32;
    config.idle_timeout_ms = option_value(argv, "idle", 0);
    config.max_write_queue_bytes = option_value(argv, "queue", config.max_write_queue_bytes);
    config.read_buffer_bytes = option_value(argv, "read", config.read_buffer_bytes);
    config.shutdown_grace_ms = option_value(argv, "grace", 5000);
    config.max_conns = option_value(argv, "conns", 256);
    let started = web::tcp_serve(config, control, on_event, tick);
    print("STATS accepted=", control.stats.accepted, " closed=", control.stats.closed, " timeouts=",
        control.stats.timeouts, " rejected=", control.stats.rejected, " connects=", control.stats.connects,
        " bytes_read=", control.stats.bytes_read, " bytes_written=", control.stats.bytes_written,
        " refused=", control.stats.refused_sends, " active=", control.stats.active);
    if !started { abort("tcp server failed to start"); }
}
