import goose_web from "../..";
import std;
import os;

// A TCP proxy: each accepted client gets one upstream connection, and bytes flow both ways. Reads from a
// client wait until its upstream is connected, and each side stops reading while the other side's queue
// is above high water, so memory stays bounded. Usage: server LISTEN_PORT UPSTREAM_IP UPSTREAM_PORT
// (the upstream address must be numeric: names are not resolved).
const MAX_CONNECTIONS = 128;

var control = default<web::TcpControl>();
// Slot -> connection id of the other side of the pair (0 when none).
var partner: i64[MAX_CONNECTIONS];
// Upstream connections carry tag UPSTREAM, so their Open event is told apart from a client's.
const UPSTREAM = 1;
var upstream_host: u8[>..] = [];
var upstream_port: i32 = 0;

fn tick() {}

fn pair(net: web::TcpControl&, client: i64, upstream: i64) {
    partner[web::tcp_slot_of(net, client)] = upstream;
    partner[web::tcp_slot_of(net, upstream)] = client;
}

fn on_event(net: web::TcpControl&, ev: web::TcpEvent) {
    match ev {
        Open o => {
            if web::tcp_tag(net, o.conn) == UPSTREAM {
                // The upstream is ready: its client may send now.
                let client = partner[web::tcp_slot_of(net, o.conn)];
                web::tcp_pause_reads(net, client, false);
                return;
            }
            let up = web::tcp_connect(net, upstream_host[..], upstream_port);
            if up == web::TCP_NO_CONN {
                web::tcp_close(net, o.conn);
                return;
            }
            web::tcp_set_tag(net, up, UPSTREAM);
            pair(net, o.conn, up);
            web::tcp_pause_reads(net, o.conn, true);
        },
        Data d => {
            let other = partner[web::tcp_slot_of(net, d.conn)];
            if other == web::TCP_NO_CONN { return; }
            if !web::tcp_send(net, other, d.bytes) {
                web::tcp_close(net, d.conn);
                web::tcp_close(net, other);
                return;
            }
            if web::tcp_queued(net, other) >= web::tcp_high_water(net) {
                web::tcp_pause_reads(net, d.conn, true);
            }
        },
        Writable w => {
            // The queue to w.conn drained, so its feeder (the partner) may read again.
            web::tcp_pause_reads(net, partner[web::tcp_slot_of(net, w.conn)], false);
        },
        Closed c => {
            let slot = c.conn % web::TCP_SLOT_SPAN;
            let other = partner[slot];
            partner[slot] = web::TCP_NO_CONN;
            if other != web::TCP_NO_CONN {
                partner[other % web::TCP_SLOT_SPAN] = web::TCP_NO_CONN;
                web::tcp_close(net, other);
            }
        },
    }
}

fn main() {
    let argv = args();
    if argv.len != 4 { abort("usage: server LISTEN_PORT UPSTREAM_IP UPSTREAM_PORT"); }
    var config = web::tcp_config();
    config.handle_signals = true;
    let port, port_ok = parse_int(argv[1]);
    let upstream, upstream_ok = parse_int(argv[3]);
    if !port_ok || !upstream_ok { abort("ports must be numbers"); }
    config.port = port as i32;
    config.max_conns = MAX_CONNECTIONS;
    upstream_host.append(argv[2]);
    upstream_port = upstream as i32;
    print("tcp proxy ", config.port, " -> ", argv[2], ":", upstream_port);
    let started = web::tcp_serve(config, control, on_event, tick);
    if !started { abort("tcp server failed to start"); }
}
