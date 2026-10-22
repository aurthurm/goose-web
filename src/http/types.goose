import std;
namespace web;

const MAX_REQUEST = 8192;
struct Request {
    method: const u8[:], target: const u8[:], body: const u8[:], raw_headers: const u8[:]
}
struct Header { name: u8[..64], value: u8[..256] }
struct Response {
    status: i32, content_type: u8[..128], body: u8[..8192], headers: Header[..16]
}
