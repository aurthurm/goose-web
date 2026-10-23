import src.constants.http;
import src.constants.limits;
import .response;
import std;
namespace web;

// JSON is Unicode text. Reject malformed UTF-8 rather than emitting invalid
// JSON or silently changing the caller's message. Valid multibyte text survives.
fn error_valid_utf8(text: const u8[:]) -> bool {
    var i: i64 = 0;
    while i < text.len {
        let c = text[i];
        if c < 128 { i += 1; continue; }
        var n: i64 = 0;
        if c >= 194 && c <= 223 { n = 2; }
        else if c >= 224 && c <= 239 { n = 3; }
        else if c >= 240 && c <= 244 { n = 4; }
        else { return false; }
        if text.len - i < n { return false; }
        let second = text[i + 1];
        if (c == 224 && second < 160) || (c == 237 && second >= 160) ||
           (c == 240 && second < 144) || (c == 244 && second >= 144) { return false; }
        for j in n - 1 {
            let continuation = text[i + 1 + j];
            if continuation < 128 || continuation > 191 { return false; }
        }
        i += n;
    }
    return true;
}

// Public text boundary check for applications decoding JSON or other UTF-8 data.
// Control-character policy belongs to the consuming format, not this function.
fn valid_utf8(text: const u8[:]) -> bool { return error_valid_utf8(text); }

fn error_append(out: u8[..MAX_ERROR_BODY_BYTES]&, text: const u8[:]) -> bool {
    if text.len > MAX_ERROR_BODY_BYTES - out.len { return false; }
    out.append(text);
    return true;
}

fn error_append_string(out: u8[..MAX_ERROR_BODY_BYTES]&, text: const u8[:]) -> bool {
    if !error_append(out, "\"") { return false; }
    let hex = "0123456789abcdef";
    for c in text {
        if c == '"' || c == '\\' {
            let escaped: u8[2] = ['\\', c];
            if !error_append(out, escaped) { return false; }
        } else if c < 32 {
            let escaped: u8[6] = ['\\', 'u', '0', '0', hex[c / 16], hex[c % 16]];
            if !error_append(out, escaped) { return false; }
        } else {
            if !error_append(out, [c]) { return false; }
        }
    }
    return error_append(out, "\"");
}

fn error_fallback(result: Response&) -> bool {
    result.status = HTTP_INTERNAL_SERVER_ERROR;
    result.content_type = CONTENT_TYPE_JSON;
    drop_body(result);
    error_set_body(result, "{\"error\":{\"code\":\"internal_error\",\"message\":\"Unable to encode application error\"}}\n");
    return false;
}

// Stable schema: {"error":{"code":"...","message":"..."}} followed by LF.
// true means the requested error was represented in full. Invalid status,
// malformed UTF-8, or capacity exhaustion returns false with a complete 500
// response, never a partial/truncated JSON document. Existing headers survive.
fn application_error(result: Response&, status: i32, code: const u8[:], message: const u8[:]) -> bool {
    if status < HTTP_MIN_ERROR_STATUS || status > HTTP_MAX_STATUS || !error_valid_utf8(code) || !error_valid_utf8(message) {
        return error_fallback(result);
    }
    // Inputs may borrow the response body or content type. Consume both in
    // full into a local before the response is changed.
    var body: u8[..MAX_ERROR_BODY_BYTES] = [];
    if !error_append(body, "{\"error\":{\"code\":") || !error_append_string(body, code) ||
       !error_append(body, ",\"message\":") || !error_append_string(body, message) ||
       !error_append(body, "}}\n") { return error_fallback(result); }
    if !error_set_body(result, body[..]) { return error_fallback(result); }
    result.content_type = CONTENT_TYPE_JSON;
    result.status = status;
    return true;
}
