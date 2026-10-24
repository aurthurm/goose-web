import src.constants.http;
import src.constants.limits;
import src.http.headers;
import src.http.request;
import src.app.context;
import std;
namespace web;

// Trusted-proxy client address. When the TCP peer is one of the trusted networks, the client is the
// first untrusted address found walking the forwarded chain from its right end (see client_ip_of).
// Otherwise the client is the TCP peer, so a header from an untrusted peer never changes anything.
// See docs/api.md#trusted-proxies.

const PROXY_MAX_CIDRS = 16;
const PROXY_MAX_HEADER_LINES = 16;
const HEADER_X_FORWARDED_FOR = "X-Forwarded-For";
const HEADER_FORWARDED = "Forwarded";
// Address families as used in Cidr.family. IPv4-mapped IPv6 addresses (::ffff:a.b.c.d) are folded to IPv4.
const IP_FAMILY_4 = 4;
const IP_FAMILY_6 = 6;

// A network: family 4 keeps its address in addr[0..4], family 6 in addr[0..16]. bits is the prefix length.
struct Cidr { family: i32, addr: u8[16], bits: i32 }
// The trusted networks. valid is false when trusted_proxies refused an entry. forwarded: read the RFC 7239
// Forwarded header instead of X-Forwarded-For.
struct ProxyConfig { nets: Cidr[PROXY_MAX_CIDRS], count: i64, forwarded: bool, valid: bool }

// Value of one hex digit, or -1.
fn hex_digit_value(c: u8) -> i64 {
    if c >= '0' && c <= '9' { return (c - '0'); }
    if c >= 'a' && c <= 'f' { return (c - 'a') as i64 + 10; }
    if c >= 'A' && c <= 'F' { return (c - 'A') as i64 + 10; }
    return -1;
}

// Dotted quad with four decimal octets 0-255. Leading zeros are refused, so "010" is not read as octal.
// Writes four bytes into out.
fn ip_parse4(text: const u8[:], out: u8[:]) -> bool {
    var octet: i64 = 0;
    var digits: i64 = 0;
    var count: i64 = 0;
    for i in text.len {
        let c = text[i];
        if c >= '0' && c <= '9' {
            if digits == 1 && octet == 0 { return false; }
            octet = octet * 10 + (c - '0');
            digits += 1;
            if digits > 3 || octet > 255 { return false; }
        } else if c == '.' {
            if digits == 0 || count == 3 { return false; }
            out[count] = octet as u8;
            count += 1;
            octet = 0;
            digits = 0;
        } else {
            return false;
        }
    }
    if digits == 0 || count != 3 { return false; }
    out[3] = octet as u8;
    return true;
}

// Colon-separated hex groups appended to groups[n..]. An IPv4 dotted tail counts as two groups and is
// allowed only as the last item of a part that allows it. An empty part has no groups.
fn ip_groups6(part: const u8[:], groups: i64[8]&, n: i64&, allow_v4: bool) -> bool {
    if part.len == 0 { return true; }
    var start: i64 = 0;
    while true {
        var stop = start;
        while stop < part.len && part[stop] != ':' { stop += 1; }
        let item = part[start..stop];
        let last = stop == part.len;
        if item.len == 0 { return false; }
        if find(item, ".") >= 0 {
            if !last || !allow_v4 || n + 2 > 8 { return false; }
            var quad: u8[4] = [0; 4];
            if !ip_parse4(item, quad[..]) { return false; }
            let hi: i64 = quad[0];
            let lo: i64 = quad[1];
            groups[n] = hi * 256 + lo;
            let hi2: i64 = quad[2];
            let lo2: i64 = quad[3];
            groups[n + 1] = hi2 * 256 + lo2;
            n += 2;
        } else {
            if item.len > 4 || n >= 8 { return false; }
            var value: i64 = 0;
            for ch in item {
                let digit = hex_digit_value(ch);
                if digit < 0 { return false; }
                value = value * 16 + digit;
            }
            groups[n] = value;
            n += 1;
        }
        if last { return true; }
        start = stop + 1;
    }
    return true;
}

// IPv4 dotted quad or IPv6 text (RFC 4291, with one "::" and an optional IPv4 tail). Zone ids are refused.
// Writes 16 bytes into out (4 for IPv4) and sets family.
fn ip_parse(text: const u8[:], out: u8[:], family: i32&) -> bool {
    if text.len == 0 || text.len > 45 { return false; }
    if find(text, ":") < 0 {
        if !ip_parse4(text, out) { return false; }
        family = IP_FAMILY_4;
        return true;
    }
    var groups: i64[8] = [0; 8];
    var n: i64 = 0;
    let dc = find(text, "::");
    if dc >= 0 {
        if find(text[dc + 2..], "::") >= 0 { return false; }
        var head: i64[8] = [0; 8];
        var head_n: i64 = 0;
        var tail: i64[8] = [0; 8];
        var tail_n: i64 = 0;
        if !ip_groups6(text[..dc], head, head_n, false) { return false; }
        if !ip_groups6(text[dc + 2..], tail, tail_n, true) { return false; }
        // "::" stands for at least one group of zeros, so the explicit groups number fewer than eight.
        if head_n + tail_n >= 8 { return false; }
        for i in head_n { groups[i] = head[i]; }
        for i in tail_n { groups[8 - tail_n + i] = tail[i]; }
    } else {
        if !ip_groups6(text, groups, n, true) || n != 8 { return false; }
    }
    for i in 8 {
        out[2 * i] = (groups[i] / 256) as u8;
        out[2 * i + 1] = (groups[i] % 256) as u8;
    }
    family = IP_FAMILY_6;
    return true;
}

// True for ::ffff:a.b.c.d, the IPv4-mapped form that a dual-stack socket reports for an IPv4 client.
fn ip_mapped(addr: const u8[:]) -> bool {
    for i in 10 { if addr[i] != 0 { return false; } }
    return addr[10] == 255 && addr[11] == 255;
}

// Folds an IPv4-mapped IPv6 address to IPv4 (4 bytes, family 4), so that one IPv4 entry matches both forms.
fn ip_fold(addr: u8[:], family: i32&) {
    if family != IP_FAMILY_6 || !ip_mapped(addr) { return; }
    for i in 4 { addr[i] = addr[12 + i]; }
    family = IP_FAMILY_4;
}

// Clears the host bits of addr beyond the prefix.
fn ip_mask(addr: u8[:], family: i32, bits: i64) {
    let width: i64 = if family == IP_FAMILY_4 { 32 } else { 128 };
    for i in width / 8 {
        let remaining = bits - (i) * 8;
        if remaining >= 8 { continue; }
        if remaining <= 0 { addr[i] = 0; continue; }
        let mask: i64 = 256 - (1 << (8 - remaining));
        addr[i] = ((addr[i]) & mask) as u8;
    }
}

// "address" or "address/prefix", IPv4 (prefix 0-32) or IPv6 (prefix 0-128). A bare address is one host.
// An IPv4-mapped IPv6 network with a prefix of at least 96 is stored as IPv4.
fn cidr_parse(text: const u8[:], net: Cidr&) -> bool {
    var address = text;
    var bits: i64 = -1;
    let slash = find(text, "/");
    if slash >= 0 {
        address = text[..slash];
        let prefix, ok = parse_canonical(text[slash + 1..]);
        if !ok || prefix > 128 { return false; }
        bits = prefix;
    }
    var addr: u8[16] = [0; 16];
    var family: i32 = 0;
    if !ip_parse(address, addr[..], family) { return false; }
    if bits < 0 { bits = if family == IP_FAMILY_4 { 32 } else { 128 }; }
    if family == IP_FAMILY_6 && ip_mapped(addr[..]) && bits >= 96 {
        ip_fold(addr[..], family);
        bits -= 96;
    }
    if (family == IP_FAMILY_4 && bits > 32) || (family == IP_FAMILY_6 && bits > 128) { return false; }
    ip_mask(addr[..], family, bits);
    net.family = family;
    net.addr = addr;
    net.bits = bits as i32;
    return true;
}

// Whether addr (already folded, see ip_fold) lies in net.
fn cidr_contains(net: Cidr&, family: i32, addr: const u8[:]) -> bool {
    if net.family != family { return false; }
    let width: i64 = if family == IP_FAMILY_4 { 32 } else { 128 };
    for i in width / 8 {
        let remaining = net.bits - (i) * 8;
        if remaining <= 0 { return true; }
        var mask: i64 = 255;
        if remaining < 8 { mask = 256 - (1 << (8 - remaining)); }
        if (net.addr[i]) & mask != (addr[i]) & mask { return false; }
    }
    return true;
}

// Adds one network to the list. False, with the list unchanged, when the text is malformed or the list is full.
fn proxy_add(cfg: ProxyConfig&, cidr: const u8[:]) -> bool {
    if cfg.count >= PROXY_MAX_CIDRS { return false; }
    var net = default<Cidr>();
    if !cidr_parse(cidr, net) { return false; }
    cfg.nets[cfg.count] = net;
    cfg.count += 1;
    return true;
}

// Builds the trusted list from comma-separated entries, e.g. "127.0.0.1, 10.0.0.0/8, ::1". An empty entry,
// a malformed one, or more than PROXY_MAX_CIDRS entries make the result invalid, and trust_proxies refuses it.
fn trusted_proxies(list: const u8[:]) -> ProxyConfig {
    var cfg = default<ProxyConfig>();
    cfg.valid = true;
    var start: i64 = 0;
    while start <= list.len {
        var stop = start;
        while stop < list.len && list[stop] != ',' { stop += 1; }
        if !proxy_add(cfg, request_ows(list[start..stop])) {
            cfg.valid = false;
            return cfg;
        }
        start = stop + 1;
    }
    return cfg;
}

fn proxy_trusted(cfg: ProxyConfig&, family: i32, addr: const u8[:]) -> bool {
    for i in cfg.count {
        if cidr_contains(cfg.nets[i], family, addr) { return true; }
    }
    return false;
}

// The for= parameter of one Forwarded element (RFC 7239), unquoted, with brackets and a port removed.
// Empty when the element has no for= parameter. The result is a view into the element.
fn forwarded_for(element: const u8[:]) -> const u8[:] {
    var start: i64 = 0;
    while start <= element.len {
        var stop = start;
        while stop < element.len && element[stop] != ';' { stop += 1; }
        let pair = request_ows(element[start..stop]);
        let eq = find(pair, "=");
        if eq == 3 && equal_header(pair[..3], "for") {
            var value = request_ows(pair[eq + 1..]);
            if value.len >= 2 && value[0] == '"' && value[value.len - 1] == '"' { value = value[1..value.len - 1]; }
            if value.len >= 1 && value[0] == '[' {
                let close = find(value, "]");
                if close < 0 { return ""; }
                return value[1..close];
            }
            // A bare IPv4 address may carry a port (192.0.2.1:4711). Two colons mean bare IPv6, which keeps them.
            let colon = find(value, ":");
            if colon >= 0 && find(value[colon + 1..], ":") < 0 { return value[..colon]; }
            return value;
        }
        start = stop + 1;
    }
    return "";
}

// The client address for one request. An untrusted or unknown TCP peer is the client. A trusted peer makes
// the chain count: its headers are read right to left, trusted hops are skipped, and the first untrusted hop
// is the client. A malformed hop on the way, or no forwarded header at all, gives the peer. A chain made only
// of trusted hops gives its leftmost valid hop. Returned text is a view into the request headers.
fn client_ip_of(request: Request, cfg: ProxyConfig) -> const u8[:] {
    var addr: u8[16] = [0; 16];
    var family: i32 = 0;
    if !ip_parse(request.peer, addr[..], family) { return request.peer; }
    ip_fold(addr[..], family);
    if !proxy_trusted(cfg, family, addr[..]) { return request.peer; }
    let name = if cfg.forwarded { HEADER_FORWARDED } else { HEADER_X_FORWARDED_FOR };
    var values: const u8[:][16] = [""; 16];
    var lines: i64 = 0;
    var pos: i64 = 0;
    while pos < request.raw_headers.len {
        let rest = request.raw_headers[pos..];
        let end = find(rest, "\r\n");
        if end < 0 { break; }
        let line = rest[..end];
        let colon = find(line, ":");
        if colon > 0 && equal_header(line[..colon], name) {
            // More header lines than this is refused: the peer is the only address still known.
            if lines == PROXY_MAX_HEADER_LINES { return request.peer; }
            values[lines] = line[colon + 1..];
            lines += 1;
        }
        pos += end + 2;
    }
    if lines == 0 { return request.peer; }
    // The leftmost valid hop is remembered as a position (line, item bounds) and read back at the end.
    var have = false;
    var found_line: i64 = 0;
    var found_from: i64 = 0;
    var found_to: i64 = 0;
    var index = lines;
    while index > 0 {
        index -= 1;
        let value = values[index];
        var end = value.len;
        while true {
            var start = end;
            while start > 0 && value[start - 1] != ',' { start -= 1; }
            let item = request_ows(value[start..end]);
            let hop = if cfg.forwarded { forwarded_for(item) } else { item };
            var hop_addr: u8[16] = [0; 16];
            var hop_family: i32 = 0;
            if !ip_parse(hop, hop_addr[..], hop_family) { return request.peer; }
            ip_fold(hop_addr[..], hop_family);
            if !proxy_trusted(cfg, hop_family, hop_addr[..]) { return hop; }
            have = true;
            found_line = index;
            found_from = start;
            found_to = end;
            if start == 0 { break; }
            end = start - 1;
        }
    }
    if !have { return request.peer; }
    let found = request_ows(values[found_line][found_from..found_to]);
    return if cfg.forwarded { forwarded_for(found) } else { found };
}

// Sets the client address for the rest of this request (client_ip). Put it before rate_limit and the loggers
// that should report the real client. cfg must come from trusted_proxies and be valid, or this asserts.
// Headers are read only when the TCP peer is trusted.
fn trust_proxies<Next>(c: Ctx&, cfg: ProxyConfig) {
    assert(cfg.valid);
    c.client = client_ip_of(c.request, cfg);
    Next();
}

// The client address: the result of trust_proxies when it ran for this request, else the TCP peer
// (empty when unknown, as in unit tests that build a Request by hand).
fn client_ip(c: Ctx&) -> const u8[:] {
    if c.client.len > 0 { return c.client; }
    return peer(c);
}
