import std;
import src.constants.limits;
namespace web;

struct Request {
    method: const u8[:], target: const u8[:], body: const u8[:], raw_headers: const u8[:]
}
struct Header { name: u8[..MAX_HEADER_NAME_BYTES], value: u8[..MAX_HEADER_VALUE_BYTES] }
struct Response {
    status: i32, content_type: u8[..MAX_CONTENT_TYPE_BYTES], body: u8[..MAX_RESPONSE_BODY_BYTES], headers: Header[..MAX_RESPONSE_HEADERS]
}
