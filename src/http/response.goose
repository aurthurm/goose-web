import .types;
import .headers;
import std;
namespace web;

fn response() -> Response {
    return Response { status: 200, content_type: "text/plain; charset=utf-8", body: [], headers: [] };
}

fn reason(status: i32) -> const u8[:] {
    match status {
        200 => { return "OK"; }, 201 => { return "Created"; },
        204 => { return "No Content"; }, 400 => { return "Bad Request"; },
        401 => { return "Unauthorized"; }, 403 => { return "Forbidden"; },
        404 => { return "Not Found"; }, 405 => { return "Method Not Allowed"; },
        413 => { return "Content Too Large"; }, 417 => { return "Expectation Failed"; },
        431 => { return "Request Header Fields Too Large"; },
        500 => { return "Internal Server Error"; }, 501 => { return "Not Implemented"; },
        503 => { return "Service Unavailable"; }, 505 => { return "HTTP Version Not Supported"; },
        _ => { return "Response"; }
    }
}

fn serialize_response(out: u8[>..]&, r: Response&, head: bool = false) {
    var valid = r.status >= 200 && r.status <= 599 && r.content_type.len > 0;
    for c in r.content_type { if c < 32 || c == 127 { valid = false; } }
    for h in r.headers {
        if !valid_response_header(h.name, h.value) { valid = false; }
    }
    for i in r.headers.len {
        for j in i + 1..r.headers.len {
            if equal_header(r.headers[i].name, r.headers[j].name) { valid = false; }
        }
    }
    if !valid {
        r.status = 500;
        r.content_type = "text/plain; charset=utf-8";
        r.body = "Invalid response\n";
        r.headers.clear();
    }
    let no_body = r.status == 204 || r.status == 304;
    format(out, "HTTP/1.1 ", r.status, " ", reason(r.status), "\r\nConnection: close\r\n");
    if !no_body { format(out, "Content-Length: ", r.body.len, "\r\n"); }
    format(out, "Content-Type: ", r.content_type, "\r\n");
    for h in r.headers { format(out, h.name, ": ", h.value, "\r\n"); }
    out.append("\r\n");
    if !head && !no_body { out.append(r.body); }
}
