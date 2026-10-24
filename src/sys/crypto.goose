import std;
namespace web;

// Cryptographic primitives over native/posix/crypto.c: SHA-256, HMAC-SHA256, PBKDF2-HMAC-SHA256,
// CSPRNG bytes, constant-time comparison and unpadded base64url. The C side keeps no Goose pointers and
// sees only byte slices, so builders (u8[>..]&) are grown here and the C code writes into
// their new tail. Digests are returned by value as fixed arrays.

extern fn gw_sha256(data: const u8[:], out: u8[:]) -> i32;
extern fn gw_hmac_sha256(key: const u8[:], message: const u8[:], out: u8[:]) -> i32;
extern fn gw_random_bytes(out: u8[:]) -> i32;
extern fn gw_constant_time_equal(a: const u8[:], b: const u8[:]) -> i32;
extern fn gw_base64url_encode(src: const u8[:], out: u8[:]) -> i64;
extern fn gw_base64url_decode(src: const u8[:], out: u8[:]) -> i64;
extern fn gw_pbkdf2_sha256(password: const u8[:], salt: const u8[:], iterations: i64, out: u8[:]) -> i32;

// Digest and key sizes in bytes.
const SHA256_BYTES = 32;

// SHA-256 of `data` (FIPS 180-4).
fn sha256(data: const u8[:]) -> u8[32] {
    var digest: u8[32] = [0; 32];
    let status = gw_sha256(data, digest[..]);
    assert(status == 0);
    return digest;
}

// HMAC-SHA256 of `message` under `key` (RFC 2104). Keys of any length are accepted.
fn hmac_sha256(key: const u8[:], message: const u8[:]) -> u8[32] {
    var tag: u8[32] = [0; 32];
    let status = gw_hmac_sha256(key, message, tag[..]);
    assert(status == 0);
    return tag;
}

// Fills `out` with random bytes from getrandom(2) or /dev/urandom. False when no entropy
// source answered; callers must refuse to issue a token in that case.
fn random_bytes(out: u8[:]) -> bool {
    return gw_random_bytes(out) == 1;
}

// Equality in time that depends only on the contents when the lengths match. A length
// mismatch is reported at once, since lengths are public.
fn constant_time_equal(a: const u8[:], b: const u8[:]) -> bool {
    return gw_constant_time_equal(a, b) == 1;
}

// PBKDF2-HMAC-SHA256 (RFC 8018) of password and salt into out, which holds 1 to 1024 bytes.
// iterations is at least 1. False on bad arguments; out is then unchanged.
fn pbkdf2_sha256(password: const u8[:], salt: const u8[:], iterations: i64, out: u8[:]) -> bool {
    return gw_pbkdf2_sha256(password, salt, iterations, out) == 0;
}

// Appends the unpadded base64url text of `src` (RFC 4648 section 5) to `out`.
fn base64url_append(out: u8[>..]&, src: const u8[:]) {
    let start = out.len;
    out.resize(start + (src.len * 4 + 2) / 3, 0);
    let written = gw_base64url_encode(src, out[start..]);
    assert(written == out.len - start);
}

// Appends the bytes that `src` decodes to. False, with `out` unchanged, when `src` is not
// canonical unpadded base64url: padding, foreign symbols, a length of 1 mod 4 or nonzero
// unused bits are all refused.
fn base64url_decode(out: u8[>..]&, src: const u8[:]) -> bool {
    let start = out.len;
    out.resize(start + src.len / 4 * 3 + 2, 0);
    let written = gw_base64url_decode(src, out[start..]);
    if written < 0 {
        out.resize(start, 0);
        return false;
    }
    out.resize(start + written, 0);
    return true;
}
