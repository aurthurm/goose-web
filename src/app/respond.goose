import src.constants.http;
import src.constants.limits;
import src.http.response;
import src.http.request;
import src.http.errors;
import src.json.codec;
import src.app.context;
import src.app.validation;
import std;
namespace web;

// Reflective JSON responses and typed request bodies for the app DSL.
// Struct and scalar values go through c.json; arrays and slices go through c.json_list,
// because a generic by-value parameter and a slice overload tie on arrays and slices.

// Encoding failure (invalid UTF-8 inside the value) is a server-side defect, not a client error.
fn encode_error(c: Ctx&) {
    c.written = true;
    application_error(c.response, HTTP_INTERNAL_SERVER_ERROR, "encode_error", "Response value cannot be encoded as JSON");
}

// Keeps the status already set by c.status(), defaulting to 200. Bodies over the
// fixed capacity become a complete 500 response_too_large via write_body.
fn json<T>(c: Ctx&, value: T) {
    var out: u8[>..] = [];
    if !json_encode(out, value) {
        encode_error(c);
        return;
    }
    write_body(c, CONTENT_TYPE_JSON, out[..]);
}

// Arrays and slices of structs or scalars. Struct elements need the nested-struct
// registration from docs/api.md. A u8 slice is text under the codec rules.
fn json_list<E>(c: Ctx&, items: E[:]) {
    var out: u8[>..] = [];
    if !json_put_seq(out, items) {
        encode_error(c);
        return;
    }
    write_body(c, CONTENT_TYPE_JSON, out[..]);
}

// Media type only: parameters such as charset are ignored and the type is compared
// case-insensitively, as RFC 9110 defines it.
fn is_json_media_type(value: const u8[:]) -> bool {
    let semi = find(value, ";");
    let base = request_ows(if semi < 0 { value } else { value[..semi] });
    return equal_header(base, CONTENT_TYPE_JSON);
}

// Decodes the request body without validating it. A wrong media type writes 415, an empty or
// malformed body writes 400 invalid_json, and both leave the response written. Schema problems
// are collected in result.issues and leave the response unwritten: validate_result (or body<T>)
// reports them together with the constraint checks.
fn body_decode<T>(c: Ctx&) -> T, DecodeResult {
    var value: T = T { .. };
    if !is_json_media_type(c.header(HEADER_CONTENT_TYPE)) {
        var result = DecodeResult { .. };
        json_store(result.error, "Content-Type must be application/json");
        fail(c, HTTP_UNSUPPORTED_MEDIA_TYPE, "unsupported_media_type", "Content-Type must be application/json");
        return value, result;
    }
    if c.request.body.len == 0 {
        var result = DecodeResult { .. };
        json_store(result.error, "request body is empty");
        fail(c, HTTP_BAD_REQUEST, "invalid_json", "Request body is empty");
        return value, result;
    }
    let decoded, result = json_decode<T>(c.request.body, true);
    if result.ok || result.issues.items.len > 0 { return decoded, result; }
    let message = str("Malformed JSON: ", result.error[..]);
    fail(c, HTTP_BAD_REQUEST, "invalid_json", message[..]);
    return decoded, result;
}

// Decodes the request body. Failures write the error response before returning: 415, 400
// (empty or syntax), or 422 with detail for every schema issue. The 422 carries the decode
// issues only; body<T> also runs the constraint checks (validate_result).
fn body_result<T>(c: Ctx&) -> T, DecodeResult {
    let decoded, result = body_decode<T>(c);
    if !result.ok && !c.written && result.issues.items.len > 0 {
        var issues = result.issues;
        issues_root(issues, "body");
        issues_fail(c, "invalid_payload", issues);
    }
    return decoded, result;
}

// Decodes the request body into T, normalizes and validates it. On false the error response is
// already written: 400 for malformed JSON, 415 for the media type, or 422 with detail for every
// decode and constraint issue (docs/api.md, "Validation").
fn body<T>(c: Ctx&) -> T, bool {
    var value, result = body_decode<T>(c);
    if c.written { return value, false; }
    return value, validate_result(c, "body", value, result);
}
