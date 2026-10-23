/* SHA-256, HMAC-SHA256 (FIPS 180-4, RFC 2104), random bytes, constant-time comparison and
   base64url (RFC 4648 section 5, unpadded). Each function borrows its arguments for the call
   only and keeps no Goose pointers. Sizes are checked against the caller's buffers; a
   failing check returns an error value instead of writing past the end. */
#define _POSIX_C_SOURCE 200809L
#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#ifdef __linux__
#include <sys/random.h>
#endif

typedef struct { uint8_t *data; int64_t len; } gw_bytes;

#define GW_SHA256_DIGEST_BYTES 32
#define GW_SHA256_BLOCK_BYTES 64
#define GW_BASE64URL_ERROR (-1)

static const uint32_t gw_sha256_k[64] = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
};

typedef struct {
    uint32_t state[8];
    uint8_t block[GW_SHA256_BLOCK_BYTES];
    size_t fill;
    uint64_t total;
} gw_sha256_ctx;

static uint32_t gw_rotr(uint32_t x, unsigned n) { return (x >> n) | (x << (32 - n)); }

static void gw_sha256_compress(gw_sha256_ctx *ctx, const uint8_t *block) {
    uint32_t w[64];
    for (size_t i = 0; i < 16; i++) {
        w[i] = (uint32_t)block[4 * i] << 24 | (uint32_t)block[4 * i + 1] << 16 |
               (uint32_t)block[4 * i + 2] << 8 | (uint32_t)block[4 * i + 3];
    }
    for (size_t i = 16; i < 64; i++) {
        uint32_t s0 = gw_rotr(w[i - 15], 7) ^ gw_rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
        uint32_t s1 = gw_rotr(w[i - 2], 17) ^ gw_rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
        w[i] = w[i - 16] + s0 + w[i - 7] + s1;
    }
    uint32_t a = ctx->state[0], b = ctx->state[1], c = ctx->state[2], d = ctx->state[3];
    uint32_t e = ctx->state[4], f = ctx->state[5], g = ctx->state[6], h = ctx->state[7];
    for (size_t i = 0; i < 64; i++) {
        uint32_t s1 = gw_rotr(e, 6) ^ gw_rotr(e, 11) ^ gw_rotr(e, 25);
        uint32_t choose = (e & f) ^ (~e & g);
        uint32_t t1 = h + s1 + choose + gw_sha256_k[i] + w[i];
        uint32_t s0 = gw_rotr(a, 2) ^ gw_rotr(a, 13) ^ gw_rotr(a, 22);
        uint32_t majority = (a & b) ^ (a & c) ^ (b & c);
        uint32_t t2 = s0 + majority;
        h = g; g = f; f = e; e = d + t1;
        d = c; c = b; b = a; a = t1 + t2;
    }
    ctx->state[0] += a; ctx->state[1] += b; ctx->state[2] += c; ctx->state[3] += d;
    ctx->state[4] += e; ctx->state[5] += f; ctx->state[6] += g; ctx->state[7] += h;
}

static void gw_sha256_init(gw_sha256_ctx *ctx) {
    static const uint32_t initial[8] = {
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
    };
    memcpy(ctx->state, initial, sizeof(initial));
    ctx->fill = 0;
    ctx->total = 0;
}

static void gw_sha256_update(gw_sha256_ctx *ctx, const uint8_t *data, size_t length) {
    ctx->total += length;
    while (length > 0) {
        size_t take = GW_SHA256_BLOCK_BYTES - ctx->fill;
        if (take > length) take = length;
        memcpy(ctx->block + ctx->fill, data, take);
        ctx->fill += take;
        data += take;
        length -= take;
        if (ctx->fill == GW_SHA256_BLOCK_BYTES) {
            gw_sha256_compress(ctx, ctx->block);
            ctx->fill = 0;
        }
    }
}

static void gw_sha256_final(gw_sha256_ctx *ctx, uint8_t *out) {
    uint64_t bits = ctx->total * 8;
    uint8_t pad = 0x80;
    gw_sha256_update(ctx, &pad, 1);
    uint8_t zero = 0;
    while (ctx->fill != 56) gw_sha256_update(ctx, &zero, 1);
    uint8_t length[8];
    for (size_t i = 0; i < 8; i++) length[i] = (uint8_t)(bits >> (56 - 8 * i));
    gw_sha256_update(ctx, length, 8);
    for (size_t i = 0; i < 8; i++) {
        out[4 * i] = (uint8_t)(ctx->state[i] >> 24);
        out[4 * i + 1] = (uint8_t)(ctx->state[i] >> 16);
        out[4 * i + 2] = (uint8_t)(ctx->state[i] >> 8);
        out[4 * i + 3] = (uint8_t)ctx->state[i];
    }
}

/* SHA-256 of data into out, which must hold exactly 32 bytes. Returns 0 on success, -1 otherwise. */
int32_t gw_sha256(gw_bytes data, gw_bytes out) {
    if (out.len != GW_SHA256_DIGEST_BYTES || data.len < 0) return -1;
    gw_sha256_ctx ctx;
    gw_sha256_init(&ctx);
    if (data.len > 0) gw_sha256_update(&ctx, data.data, (size_t)data.len);
    gw_sha256_final(&ctx, out.data);
    return 0;
}

/* HMAC-SHA256 (RFC 2104). The key may be any length; keys over one block are hashed first.
   out must hold exactly 32 bytes. Returns 0 on success, -1 otherwise. */
int32_t gw_hmac_sha256(gw_bytes key, gw_bytes message, gw_bytes out) {
    if (out.len != GW_SHA256_DIGEST_BYTES || key.len < 0 || message.len < 0) return -1;
    uint8_t block_key[GW_SHA256_BLOCK_BYTES];
    memset(block_key, 0, sizeof(block_key));
    if (key.len > GW_SHA256_BLOCK_BYTES) {
        gw_bytes hashed_key = {key.data, key.len};
        gw_bytes digest = {block_key, GW_SHA256_DIGEST_BYTES};
        if (gw_sha256(hashed_key, digest) != 0) return -1;
    } else if (key.len > 0) {
        memcpy(block_key, key.data, (size_t)key.len);
    }
    uint8_t pad[GW_SHA256_BLOCK_BYTES];
    uint8_t inner[GW_SHA256_DIGEST_BYTES];
    gw_sha256_ctx ctx;
    for (size_t i = 0; i < GW_SHA256_BLOCK_BYTES; i++) pad[i] = block_key[i] ^ 0x36;
    gw_sha256_init(&ctx);
    gw_sha256_update(&ctx, pad, sizeof(pad));
    if (message.len > 0) gw_sha256_update(&ctx, message.data, (size_t)message.len);
    gw_sha256_final(&ctx, inner);
    for (size_t i = 0; i < GW_SHA256_BLOCK_BYTES; i++) pad[i] = block_key[i] ^ 0x5c;
    gw_sha256_init(&ctx);
    gw_sha256_update(&ctx, pad, sizeof(pad));
    gw_sha256_update(&ctx, inner, sizeof(inner));
    gw_sha256_final(&ctx, out.data);
    return 0;
}

/* Fills out with cryptographically secure random bytes: getrandom(2) on Linux, then
   /dev/urandom when the call is unavailable. Returns 1 on success, 0 on failure. */
int32_t gw_random_bytes(gw_bytes out) {
    if (out.len < 0) return 0;
    size_t want = (size_t)out.len;
    size_t total = 0;
#ifdef __linux__
    while (total < want) {
        ssize_t n = getrandom(out.data + total, want - total, 0);
        if (n < 0) {
            if (errno == EINTR) continue;
            break;
        }
        total += (size_t)n;
    }
    if (total == want) return 1;
#endif
    int fd = open("/dev/urandom", O_RDONLY | O_CLOEXEC);
    if (fd < 0) return 0;
    total = 0;
    while (total < want) {
        ssize_t n = read(fd, out.data + total, want - total);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) break;
        total += (size_t)n;
    }
    close(fd);
    return total == want ? 1 : 0;
}

/* Compares two byte strings in time that depends only on their contents. Lengths are not secret,
   so a length mismatch returns at once. */
int32_t gw_constant_time_equal(gw_bytes a, gw_bytes b) {
    if (a.len != b.len || a.len < 0) return 0;
    uint8_t difference = 0;
    for (int64_t i = 0; i < a.len; i++) difference |= (uint8_t)(a.data[i] ^ b.data[i]);
    return difference == 0;
}

static int gw_base64url_symbol(uint32_t value) {
    if (value < 26) return (int)('A' + value);
    if (value < 52) return (int)('a' + (value - 26));
    if (value < 62) return (int)('0' + (value - 52));
    return value == 62 ? '-' : '_';
}

static int gw_base64url_value(uint8_t c) {
    if (c >= 'A' && c <= 'Z') return c - 'A';
    if (c >= 'a' && c <= 'z') return c - 'a' + 26;
    if (c >= '0' && c <= '9') return c - '0' + 52;
    if (c == '-') return 62;
    if (c == '_') return 63;
    return -1;
}

/* Unpadded base64url of in into out. Returns the number of bytes written, or -1 when out is too
   small. The output length is ceil(4 * n / 3) for n input bytes. */
int64_t gw_base64url_encode(gw_bytes in, gw_bytes out) {
    if (in.len < 0 || out.len < 0) return GW_BASE64URL_ERROR;
    int64_t needed = (in.len * 4 + 2) / 3;
    if (out.len < needed) return GW_BASE64URL_ERROR;
    int64_t at = 0;
    int64_t i = 0;
    for (; i + 3 <= in.len; i += 3) {
        uint32_t group = (uint32_t)in.data[i] << 16 | (uint32_t)in.data[i + 1] << 8 | in.data[i + 2];
        out.data[at++] = (uint8_t)gw_base64url_symbol((group >> 18) & 63);
        out.data[at++] = (uint8_t)gw_base64url_symbol((group >> 12) & 63);
        out.data[at++] = (uint8_t)gw_base64url_symbol((group >> 6) & 63);
        out.data[at++] = (uint8_t)gw_base64url_symbol(group & 63);
    }
    if (in.len - i == 1) {
        uint32_t group = (uint32_t)in.data[i] << 16;
        out.data[at++] = (uint8_t)gw_base64url_symbol((group >> 18) & 63);
        out.data[at++] = (uint8_t)gw_base64url_symbol((group >> 12) & 63);
    } else if (in.len - i == 2) {
        uint32_t group = (uint32_t)in.data[i] << 16 | (uint32_t)in.data[i + 1] << 8;
        out.data[at++] = (uint8_t)gw_base64url_symbol((group >> 18) & 63);
        out.data[at++] = (uint8_t)gw_base64url_symbol((group >> 12) & 63);
        out.data[at++] = (uint8_t)gw_base64url_symbol((group >> 6) & 63);
    }
    return at;
}

/* Strict unpadded base64url decode of in into out. Rejects characters outside the alphabet,
   '=' padding, a length that is 1 mod 4, and nonzero unused bits in the final symbol, so every
   byte string has exactly one encoding. Returns the number of bytes written, or -1 on any error,
   including an out buffer smaller than the decoded length. */
int64_t gw_base64url_decode(gw_bytes in, gw_bytes out) {
    if (in.len < 0 || out.len < 0) return GW_BASE64URL_ERROR;
    if (in.len % 4 == 1) return GW_BASE64URL_ERROR;
    int64_t bytes = (in.len / 4) * 3 + (in.len % 4 == 0 ? 0 : in.len % 4 - 1);
    if (out.len < bytes) return GW_BASE64URL_ERROR;
    int64_t at = 0;
    uint32_t group = 0;
    unsigned bits = 0;
    for (int64_t i = 0; i < in.len; i++) {
        int value = gw_base64url_value(in.data[i]);
        if (value < 0) return GW_BASE64URL_ERROR;
        group = (group << 6) | (uint32_t)value;
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            out.data[at++] = (uint8_t)((group >> bits) & 0xff);
        }
    }
    if (bits > 0 && (group & ((1u << bits) - 1)) != 0) return GW_BASE64URL_ERROR;
    return at;
}
