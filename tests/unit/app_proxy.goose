// Trusted proxies: IP and CIDR parsing, the allow-list, X-Forwarded-For and Forwarded walking, spoofing
// from untrusted peers, and the trust_proxies middleware with client_ip.
import goose_web from "../..";
import std;

var shared_response = web::response();
var shared_scratch = web::AppScratch { .. };

fn request_from(peer: const u8[:], headers: const u8[:]) -> web::Request {
    return web::Request { method: "GET", target: "/", body: "", raw_headers: headers, peer: peer };
}

// Parses text as an address and reports whether it is trusted by cfg (IPv4-mapped forms are folded first).
fn trusted_ip(cfg: web::ProxyConfig, text: const u8[:]) -> bool {
    var addr: u8[16] = [0; 16];
    var family: i32 = 0;
    assert(web::ip_parse(text, addr[..], family));
    web::ip_fold(addr[..], family);
    var list = cfg;
    return web::proxy_trusted(list, family, addr[..]);
}

fn parses(text: const u8[:]) -> bool {
    var addr: u8[16] = [0; 16];
    var family: i32 = 0;
    return web::ip_parse(text, addr[..], family);
}

// --- address parsing -------------------------------------------------------------

fn test_ip_parse_accepts() {
    var out: u8[16] = [0; 16];
    var family: i32 = 0;
    assert(web::ip_parse("127.0.0.1", out[..], family) && family == 4 && out[0] == 127 && out[3] == 1);
    assert(web::ip_parse("::1", out[..], family) && family == 6 && out[15] == 1 && out[0] == 0);
    assert(web::ip_parse("2001:db8::8a2e:370:7334", out[..], family) && family == 6 && out[0] == 0x20 && out[1] == 0x01);
    assert(web::ip_parse("::", out[..], family) && family == 6);
    assert(web::ip_parse("::1.2.3.4", out[..], family) && family == 6 && out[12] == 1 && out[15] == 4);
    assert(web::ip_parse("1:2:3:4:5:6:7:8", out[..], family) && family == 6 && out[15] == 8);
    assert(web::ip_parse("::ffff:192.0.2.1", out[..], family) && family == 6);
    assert(web::ip_parse("0.0.0.0", out[..], family) && family == 4);
    assert(web::ip_parse("255.255.255.255", out[..], family) && family == 4);
}

fn test_ip_parse_refuses() {
    assert(!parses(""));
    assert(!parses("256.1.1.1"));
    assert(!parses("01.2.3.4"));
    assert(!parses("1.2.3"));
    assert(!parses("1.2.3.4.5"));
    assert(!parses("1.2.3.a"));
    assert(!parses("1.2.3.4:80"));
    assert(!parses("1.2.3."));
    assert(!parses("1::2::3"));
    assert(!parses("1:::2"));
    assert(!parses("1:2:3:4:5:6:7"));
    assert(!parses("1:2:3:4:5:6:7:8:9"));
    assert(!parses("1::2:3:4:5:6:7:8"));
    assert(!parses("12345::"));
    assert(!parses("g::1"));
    assert(!parses("::1%eth0"));
    assert(!parses("1.2.3.4::"));
    assert(!parses("[::1]"));
    assert(!parses("unknown"));
    assert(!parses("_hidden"));
}

// --- networks --------------------------------------------------------------------

fn test_cidr_table() {
    var cfg = web::trusted_proxies("10.0.0.0/8, 192.168.1.7, 2001:db8::/32");
    assert(cfg.valid && cfg.count == 3);
    assert(trusted_ip(cfg, "10.1.2.3"));
    assert(trusted_ip(cfg, "10.255.255.255"));
    assert(trusted_ip(cfg, "192.168.1.7"));
    assert(!trusted_ip(cfg, "192.168.1.8"));
    assert(trusted_ip(cfg, "2001:db8:ffff::1"));
    assert(!trusted_ip(cfg, "203.0.113.9"));
    // 0.0.0.0/0 trusts every IPv4 address.
    var everything = web::trusted_proxies("0.0.0.0/0");
    assert(trusted_ip(everything, "203.0.113.9") && !trusted_ip(everything, "2001:db8::1"));

    var narrow = web::trusted_proxies("10.0.0.0/8");
    assert(!trusted_ip(narrow, "11.0.0.1"));
    assert(!trusted_ip(narrow, "2001:db8::1"));
    assert(!trusted_ip(narrow, "9.255.255.255"));

    // Host bits are cleared: 10.1.2.3/8 is the network 10.0.0.0/8.
    var host_bits = web::trusted_proxies("10.1.2.3/8");
    assert(host_bits.valid && trusted_ip(host_bits, "10.200.0.1"));

    // A bare address is a single host.
    var single = web::trusted_proxies("::1");
    assert(trusted_ip(single, "::1") && !trusted_ip(single, "::2"));

    // IPv4-mapped IPv6 addresses match IPv4 entries (a dual-stack socket reports IPv4 clients that way).
    var mapped = web::trusted_proxies("127.0.0.1/32");
    assert(trusted_ip(mapped, "::ffff:127.0.0.1"));
    assert(!trusted_ip(mapped, "::ffff:127.0.0.2"));
    var mapped_net = web::trusted_proxies("::ffff:10.0.0.0/104");
    assert(mapped_net.valid && trusted_ip(mapped_net, "10.9.9.9") && !trusted_ip(mapped_net, "11.0.0.1"));
}

fn test_cidr_refused() {
    assert(!web::trusted_proxies("10.0.0.0/33").valid);
    assert(!web::trusted_proxies("::/129").valid);
    assert(!web::trusted_proxies("10.0.0.0/x").valid);
    assert(!web::trusted_proxies("/8").valid);
    assert(!web::trusted_proxies("10.0.0.0/").valid);
    assert(!web::trusted_proxies("10.0.0.0/08").valid);
    assert(!web::trusted_proxies("10.0.0.0/8,").valid);
    assert(!web::trusted_proxies("").valid);
    assert(!web::trusted_proxies("10.0.0.0/8,,127.0.0.1").valid);
}

fn test_cidr_list_limit() {
    var sixteen: u8[>..] = [];
    for i in 16 {
        if i > 0 { sixteen.push(','); }
        sixteen.append("1.1.1.1");
    }
    assert(web::trusted_proxies(sixteen[..]).valid);
    sixteen.append(",1.1.1.1");
    assert(!web::trusted_proxies(sixteen[..]).valid);
}

// --- X-Forwarded-For walking -----------------------------------------------------

fn client_of(cfg: web::ProxyConfig, peer: const u8[:], headers: const u8[:]) -> const u8[:] {
    return web::client_ip_of(request_from(peer, headers), cfg);
}

fn test_xff_walk() {
    var cfg = web::trusted_proxies("127.0.0.1/32, 10.0.0.0/8");
    // Peer trusted, one untrusted hop: that hop is the client.
    assert(client_of(cfg, "127.0.0.1", "X-Forwarded-For: 203.0.113.9\r\n") == "203.0.113.9");
    // Trusted hops on the right are skipped; the first untrusted hop from the right wins.
    assert(client_of(cfg, "127.0.0.1", "X-Forwarded-For: 198.51.100.7, 10.1.1.1\r\n") == "198.51.100.7");
    assert(client_of(cfg, "127.0.0.1", "X-Forwarded-For: 198.51.100.7, 10.1.1.1, 127.0.0.1\r\n") == "198.51.100.7");
    // Spoofing: the client prepended its own value; the proxy appended the real one on the right.
    assert(client_of(cfg, "127.0.0.1", "X-Forwarded-For: 1.2.3.4, 203.0.113.9\r\n") == "203.0.113.9");
    // Surrounding whitespace is not part of the address.
    assert(client_of(cfg, "127.0.0.1", "X-Forwarded-For:  203.0.113.9 ,  10.1.1.1  \r\n") == "203.0.113.9");
    // Several header lines count as one list, in order.
    assert(client_of(cfg, "127.0.0.1", "X-Forwarded-For: 198.51.100.7\r\nX-Forwarded-For: 10.1.1.1\r\n") == "198.51.100.7");
    assert(client_of(cfg, "127.0.0.1", "X-Forwarded-For: 198.51.100.7\r\nX-Forwarded-For: 10.1.1.1, 127.0.0.1\r\n") == "198.51.100.7");
    // Header names are case-insensitive.
    assert(client_of(cfg, "127.0.0.1", "x-forwarded-for: 203.0.113.9\r\n") == "203.0.113.9");
    // IPv6 clients.
    assert(client_of(cfg, "127.0.0.1", "X-Forwarded-For: 2001:db8::5, 10.1.1.1\r\n") == "2001:db8::5");
    // A chain made only of trusted hops gives its leftmost valid hop.
    assert(client_of(cfg, "127.0.0.1", "X-Forwarded-For: 10.0.0.2, 10.0.0.3\r\n") == "10.0.0.2");
    // No forwarded header: the peer.
    assert(client_of(cfg, "127.0.0.1", "Host: x\r\n") == "127.0.0.1");
    // IPv4-mapped peer is recognised as the trusted IPv4 entry.
    assert(client_of(cfg, "::ffff:127.0.0.1", "X-Forwarded-For: 203.0.113.9\r\n") == "203.0.113.9");
}

fn test_xff_malformed_falls_back_to_peer() {
    var cfg = web::trusted_proxies("127.0.0.1/32, 10.0.0.0/8");
    // A malformed hop reached while walking gives the peer.
    assert(client_of(cfg, "127.0.0.1", "X-Forwarded-For: garbage, 10.1.1.1\r\n") == "127.0.0.1");
    assert(client_of(cfg, "127.0.0.1", "X-Forwarded-For: 1.2.3.4:80\r\n") == "127.0.0.1");
    assert(client_of(cfg, "127.0.0.1", "X-Forwarded-For: 300.1.1.1\r\n") == "127.0.0.1");
    // Empty entries: "a,,b" and a trailing comma are malformed.
    assert(client_of(cfg, "127.0.0.1", "X-Forwarded-For: 203.0.113.9,,10.1.1.1\r\n") == "127.0.0.1");
    assert(client_of(cfg, "127.0.0.1", "X-Forwarded-For: 203.0.113.9, \r\n") == "127.0.0.1");
    assert(client_of(cfg, "127.0.0.1", "X-Forwarded-For: \r\n") == "127.0.0.1");
    // A malformed entry to the left of the first untrusted hop is never reached, so it does not matter.
    assert(client_of(cfg, "127.0.0.1", "X-Forwarded-For: garbage, 203.0.113.9, 10.1.1.1\r\n") == "203.0.113.9");
    // Too many header lines: the peer.
    var lines: u8[>..] = [];
    for i in 17 { lines.append("X-Forwarded-For: 203.0.113.9\r\n"); }
    assert(client_of(cfg, "127.0.0.1", lines[..]) == "127.0.0.1");
}

fn test_xff_untrusted_peer_is_never_believed() {
    var cfg = web::trusted_proxies("127.0.0.1/32, 10.0.0.0/8");
    // An outside client sends its own forwarded header: the header is ignored.
    assert(client_of(cfg, "203.0.113.50", "X-Forwarded-For: 10.0.0.1\r\n") == "203.0.113.50");
    assert(client_of(cfg, "203.0.113.50", "X-Forwarded-For: 127.0.0.1\r\n") == "203.0.113.50");
    assert(client_of(cfg, "2001:db8::77", "X-Forwarded-For: 198.51.100.7\r\n") == "2001:db8::77");
    // An unknown peer stays unknown.
    assert(client_of(cfg, "", "X-Forwarded-For: 198.51.100.7\r\n") == "");
}

// --- Forwarded (RFC 7239) --------------------------------------------------------

fn test_forwarded_walk() {
    var cfg = web::trusted_proxies("127.0.0.1/32, 10.0.0.0/8");
    cfg.forwarded = true;
    assert(client_of(cfg, "127.0.0.1", "Forwarded: for=10.1.1.1\r\n") == "10.1.1.1");
    assert(client_of(cfg, "127.0.0.1", "Forwarded: for=\"[2001:db8::5]:4711\";proto=https, for=10.1.1.1\r\n") == "2001:db8::5");
    assert(client_of(cfg, "127.0.0.1", "Forwarded: for=192.0.2.60:80;by=10.0.0.9\r\n") == "192.0.2.60");
    assert(client_of(cfg, "127.0.0.1", "Forwarded: for=198.51.100.7, for=10.1.1.1\r\n") == "198.51.100.7");
    // Parameters without for=, obfuscated identifiers and "unknown" are malformed hops: the peer wins.
    assert(client_of(cfg, "127.0.0.1", "Forwarded: proto=https\r\n") == "127.0.0.1");
    assert(client_of(cfg, "127.0.0.1", "Forwarded: for=_hidden\r\n") == "127.0.0.1");
    assert(client_of(cfg, "127.0.0.1", "Forwarded: for=unknown, for=10.1.1.1\r\n") == "127.0.0.1");
    // The X-Forwarded-For header is ignored when Forwarded is configured.
    assert(client_of(cfg, "127.0.0.1", "X-Forwarded-For: 198.51.100.7\r\n") == "127.0.0.1");
}

// --- configuration and middleware --------------------------------------------------

fn test_trust_proxies_middleware() {
    var out = web::response();
    var scratch = web::AppScratch { .. };
    var c = web::new_ctx(request_from("127.0.0.1", "Host: x\r\nX-Forwarded-For: 203.0.113.9, 10.1.1.1\r\nUser-Agent: t\r\n"), out, scratch);
    // Before the middleware, client_ip is the peer.
    assert(web::client_ip(c) == "127.0.0.1");
    var reached = false;
    web::trust_proxies(c, web::trusted_proxies("127.0.0.1/32, 10.0.0.0/8")) {
        reached = true;
        assert(web::client_ip(c) == "203.0.113.9");
        assert(web::peer(c) == "127.0.0.1");
    };
    assert(reached);
}

fn test_trust_proxies_untrusted_peer() {
    var out = web::response();
    var scratch = web::AppScratch { .. };
    var c = web::new_ctx(request_from("203.0.113.50", "Host: x\r\nX-Forwarded-For: 10.0.0.1\r\n"), out, scratch);
    web::trust_proxies(c, web::trusted_proxies("127.0.0.1/32")) { };
    assert(web::client_ip(c) == "203.0.113.50");
}

fn main() {
    test_ip_parse_accepts();
    test_ip_parse_refuses();
    test_cidr_table();
    test_cidr_refused();
    test_cidr_list_limit();
    test_xff_walk();
    test_xff_malformed_falls_back_to_peer();
    test_xff_untrusted_peer_is_never_believed();
    test_forwarded_walk();
    test_trust_proxies_middleware();
    test_trust_proxies_untrusted_peer();
    print("Trusted proxy tests passed: parsing, CIDR table, X-Forwarded-For and Forwarded walks, spoofing, middleware");
}
