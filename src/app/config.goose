import src.constants.limits;
import src.runtime.server;
import src.sys.process;
import std;
namespace web;

// Configuration from the command line and environment, so example mains stay short. Each
// function starts from server_config() and returns `config, ok, message`: when ok is false,
// message says what was wrong and config must not be used. Ranges are the runtime's, enforced
// by validate_server_config before anything is returned as ok.
//
// Command line (argv[0] is the program name, as from args()):
//   [port]                 a bare first argument is the port, as in the original examples
//   --port N               1..65535
//   --host public|loopback public_bind = true (all IPv4 interfaces) or false (127.0.0.1)
//   --max-clients N        1..MAX_CLIENTS
//   --max-requests N       0 = unlimited; stop after N completed responses
// Each option also accepts --name=value. Other arguments are errors, so an application that
// takes its own positional arguments passes only the prefix it owns (see examples/basic).
//
// Environment: GOOSE_WEB_PORT takes the --port rule. GOOSE_WEB_PUBLIC takes "1" or "true" for
// public, "0" or "false" for loopback. Unset and empty variables keep the defaults.

const OPTION_OK = 0;
const OPTION_UNKNOWN = 1;
const OPTION_INVALID = 2;
// Numbers longer than this are refused before parsing, so the value always fits in i64.
const CONFIG_MAX_DIGITS = 18;

// Unsigned decimal only: no sign, no spaces, no separators.
fn parse_config_number(text: const u8[:], out: i64&) -> bool {
    if text.len == 0 || text.len > CONFIG_MAX_DIGITS { return false; }
    var value: i64 = 0;
    for i in text.len {
        let ch = text[i];
        if ch < '0' || ch > '9' { return false; }
        value = value * 10 + ch - '0';
    }
    out = value;
    return true;
}

fn port_text(text: const u8[:], out: i32&) -> bool {
    var value: i64 = 0;
    if !parse_config_number(text, value) || value < MIN_PORT || value > MAX_PORT { return false; }
    out = value as i32;
    return true;
}

fn clients_text(text: const u8[:], out: i64&) -> bool {
    var value: i64 = 0;
    if !parse_config_number(text, value) || value < 1 || value > MAX_CLIENTS { return false; }
    out = value;
    return true;
}

fn requests_text(text: const u8[:], out: i64&) -> bool {
    var value: i64 = 0;
    if !parse_config_number(text, value) { return false; }
    out = value;
    return true;
}

fn host_text(text: const u8[:], out: bool&) -> bool {
    if text == "public" { out = true; return true; }
    if text == "loopback" { out = false; return true; }
    return false;
}

fn switch_text(text: const u8[:], out: bool&) -> bool {
    if text == "1" || text == "true" { out = true; return true; }
    if text == "0" || text == "false" { out = false; return true; }
    return false;
}

fn is_option(arg: const u8[:]) -> bool {
    return arg.len >= 2 && arg[0] == '-' && arg[1] == '-';
}

// Applies one --name value pair. The name is the exact flag spelling.
fn set_option(config: ServerConfig&, name: const u8[:], value: const u8[:]) -> i32 {
    if name == "--port" {
        if port_text(value, config.port) { return OPTION_OK; }
        return OPTION_INVALID;
    }
    if name == "--host" {
        if host_text(value, config.public_bind) { return OPTION_OK; }
        return OPTION_INVALID;
    }
    if name == "--max-clients" {
        if clients_text(value, config.max_clients) { return OPTION_OK; }
        return OPTION_INVALID;
    }
    if name == "--max-requests" {
        if requests_text(value, config.max_requests) { return OPTION_OK; }
        return OPTION_INVALID;
    }
    return OPTION_UNKNOWN;
}

fn argument_failure(message: u8[>..]) -> ServerConfig, bool, u8[>..] {
    return server_config(), false, message;
}

fn option_failure(status: i32, name: const u8[:], value: const u8[:]) -> ServerConfig, bool, u8[>..] {
    if status == OPTION_UNKNOWN { return argument_failure(str("unknown option: ", name)); }
    return argument_failure(str("invalid value for ", name, ": ", value));
}

// Parses argv (argv[0] is the program name). See the comment above for the grammar.
fn config_from_args(argv: u8[:][:]) -> ServerConfig, bool, u8[>..] {
    var config = server_config();
    var i: i64 = 1;
    if argv.len > 1 && !is_option(argv[1]) {
        if !port_text(argv[1], config.port) {
            return argument_failure(str("invalid port: ", argv[1]));
        }
        i = 2;
    }
    while i < argv.len {
        let arg = argv[i];
        if !is_option(arg) { return argument_failure(str("unexpected argument: ", arg)); }
        // Each branch passes its own slices; Goose does not rebind a variable to a new source.
        let equals = find(arg, "=");
        if equals >= 0 {
            let status = set_option(config, arg[..equals], arg[equals + 1..]);
            if status != OPTION_OK { return option_failure(status, arg[..equals], arg[equals + 1..]); }
            i += 1;
        } else {
            if i + 1 >= argv.len { return argument_failure(str(arg, " needs a value")); }
            let status = set_option(config, arg, argv[i + 1]);
            if status != OPTION_OK { return option_failure(status, arg, argv[i + 1]); }
            i += 2;
        }
    }
    if !validate_server_config(config) { return argument_failure("invalid server configuration"); }
    return config, true, "";
}

fn env_failure(name: const u8[:]) -> ServerConfig, bool, u8[>..] {
    return argument_failure(str("invalid environment variable ", name));
}

// Reads GOOSE_WEB_PORT and GOOSE_WEB_PUBLIC over the defaults. Too-long values are invalid.
fn config_from_env() -> ServerConfig, bool, u8[>..] {
    var config = server_config();
    var text: u8[ENV_VALUE_MAX_BYTES] = [0; ENV_VALUE_MAX_BYTES];
    let port_length = getenv_into("GOOSE_WEB_PORT", text[..]);
    if port_length == ENV_TOO_LONG { return env_failure("GOOSE_WEB_PORT"); }
    if port_length > 0 && !port_text(text[..port_length], config.port) { return env_failure("GOOSE_WEB_PORT"); }
    let public_length = getenv_into("GOOSE_WEB_PUBLIC", text[..]);
    if public_length == ENV_TOO_LONG { return env_failure("GOOSE_WEB_PUBLIC"); }
    if public_length > 0 && !switch_text(text[..public_length], config.public_bind) { return env_failure("GOOSE_WEB_PUBLIC"); }
    if !validate_server_config(config) { return argument_failure("invalid server configuration"); }
    return config, true, "";
}
