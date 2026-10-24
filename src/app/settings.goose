// Typed application settings from the environment (docs/api.md, "Settings"):
//
//     struct AppSettings { port: i64 = 8080, debug: bool = false, token: u8[..64] = "" }
//     fn web::rules(v: AppSettings&, r: web::Rules&) {
//         r.field("port").ge(1).le(65535);
//         r.field("token").required().min_len(16).secret();
//     }
//     let s, issues = web::settings<AppSettings>("APP_");
//
// For each field the variable is PREFIX + the field name in upper case (APP_PORT). A field may
// also come from a file: PREFIX + NAME + "_FILE" names a file whose bytes (without one trailing
// newline) are the value, for secrets mounted as files. Setting both is an error. Empty and
// unset variables leave the field at its default.
//
// Values parse per type: integers in canonical decimal, floats with parse_flt, and text as
// given (text must fit its capacity). Booleans are lax: true, 1, on, yes and false, 0, off, no.
// Every problem is collected, not only the first, and the rules apply as they do to a body
// (missing required fields, bounds, patterns). A `.secret()` field never shows its value: its
// messages are replaced by a redacted one. Field names are used as the issue locations.
//
// Settings use the field names only (no json_key), so the names are fixed by the struct.
// Only scalar and text fields are supported; load settings once at startup, then call
// check_rules<T>() to catch a broken rules table before the values are read.
import src.constants.limits;
import src.sys.process;
import src.sys.files;
import src.json.issues;
import src.app.validation;
import std;
namespace web;

// Largest *_FILE secret read, in bytes. Secrets are short; larger files are refused.
const SETTINGS_FILE_MAX_BYTES = 4096;

// Upper-cases ASCII letters of the field name and puts the prefix in front.
fn settings_name(prefix: const u8[:], field: const u8[:], suffix: const u8[:]) -> u8[>..] {
    var name: u8[>..] = [];
    name.append(prefix);
    for c in field {
        if c >= 'a' && c <= 'z' { name.push(c - 32); } else { name.push(c); }
    }
    name.append(suffix);
    return name;
}

// Lax booleans for environment values. The stricter query rules are in query_read.
fn env_read<T>(raw: const u8[:], out: T&, reason: u8[..128]&) -> bool {
    return query_read(raw, out, reason);
}
fn env_read(raw: const u8[:], out: bool&, reason: u8[..128]&) -> bool {
    if raw == "true" || raw == "1" || raw == "on" || raw == "yes" { out = true; return true; }
    if raw == "false" || raw == "0" || raw == "off" || raw == "no" { out = false; return true; }
    json_store(reason, "expected true, false, 1, 0, on, off, yes or no");
    return false;
}

// Outcomes of reading one field.
const SETTING_UNSET = 0;
const SETTING_SET = 1;
const SETTING_ERROR = 2;

// Reads PREFIX_FIELD or PREFIX_FIELD_FILE into out. Records an issue for a problem; a secret
// field's problem never shows the value (the messages below do not carry it anyway).
fn settings_value<T>(prefix: const u8[:], field: const u8[:], secret: bool, out: T&, issues: Issues&) -> i64 {
    let name = settings_name(prefix, field, "");
    let file_name = settings_name(prefix, field, "_FILE");
    var text: u8[ENV_VALUE_MAX_BYTES] = [0; ENV_VALUE_MAX_BYTES];
    let length = getenv_into(name[..], text[..]);
    var path: u8[ENV_VALUE_MAX_BYTES] = [0; ENV_VALUE_MAX_BYTES];
    let path_length = getenv_into(file_name[..], path[..]);
    if length == ENV_TOO_LONG || path_length == ENV_TOO_LONG {
        issue_add(issues, field, "value_error", "value is too long");
        return SETTING_ERROR;
    }
    let direct = length > 0;
    let from_file = path_length > 0;
    if !direct && !from_file { return SETTING_UNSET; }
    if direct && from_file {
        issue_add(issues, field, "value_error", "set either the variable or its _FILE variable, not both");
        return SETTING_ERROR;
    }
    var raw: u8[>..] = [];
    if direct {
        raw.append(text[..length]);
    } else {
        var file_bytes: u8[>..] = [];
        let read = read_bounded_file(path[..path_length], SETTINGS_FILE_MAX_BYTES, file_bytes);
        if read != FILE_READ_OK {
            issue_add(issues, field, "value_error", "cannot read the _FILE variable's file");
            return SETTING_ERROR;
        }
        var end = file_bytes.len;
        if end > 0 && file_bytes[end - 1] == '\n' { end -= 1; }
        if end > 0 && file_bytes[end - 1] == '\r' { end -= 1; }
        raw.append(file_bytes[..end]);
    }
    var reason: u8[..128] = [];
    if !env_read(raw[..], out, reason) {
        if secret {
            issue_add(issues, field, "value_error", "invalid value (redacted)");
        } else {
            issue_add(issues, field, "value_error", reason[..]);
        }
        return SETTING_ERROR;
    }
    return SETTING_SET;
}

// Settings from the environment, with the rules of T applied. Returns the value and every
// issue (root "settings"). Check the issues before using the value: a field with an issue keeps
// its default.
fn settings<T>(prefix: const u8[:]) -> T, Issues {
    var value: T = T { .. };
    var issues = Issues { .. };
    issues_root(issues, "settings");
    let rs = rules_for(value);
    var present: u64 = 0;
    var failed: u64 = 0;
    var bit: u64 = 1;
    const for <N, A> in fields<T> {
        if !json_skip(value, N) {
            let at = rule_index(rs, N);
            var secret = false;
            if at >= 0 { secret = rs.items[at].secret; }
            let outcome = settings_value(prefix, N, secret, value.A, issues);
            if outcome == SETTING_SET { present |= bit; }
            if outcome == SETTING_ERROR { failed |= bit; }
        }
        bit <<= 1;
    }
    if issues.items.len == 0 { normalize(value); }
    validate_present(value, "settings", present, failed, issues);
    return value, issues;
}
