import goose_web from "../..";
import std;
import os;

// A TCP echo server: every byte received goes straight back. Usage: server [port]
var control = default<web::TcpControl>();

fn tick() {}

fn on_event(net: web::TcpControl&, ev: web::TcpEvent) {
    match ev {
        Data d => {
            if !web::tcp_send(net, d.conn, d.bytes) { web::tcp_close(net, d.conn); }
        },
        _ => {},
    }
}

fn main() {
    let argv = args();
    var config = web::tcp_config();
    config.handle_signals = true;
    if argv.len > 1 {
        let port, ok = parse_int(argv[1]);
        if !ok { abort("port must be a number"); }
        config.port = port as i32;
    }
    print("tcp echo listening on port ", config.port);
    let started = web::tcp_serve(config, control, on_event, tick);
    if !started { abort("tcp server failed to start"); }
}
