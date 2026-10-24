#include "../../native/posix/crypto.c"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static gw_bytes text_of(const char *s) { return (gw_bytes){(uint8_t *)s, (int64_t)strlen(s)}; }

static gw_bytes repeated(uint8_t *buffer, size_t count, uint8_t value) {
    memset(buffer, value, count);
    return (gw_bytes){buffer, (int64_t)count};
}

static void hex_to_bytes(const char *hex, uint8_t *out) {
    for (size_t i = 0; i < strlen(hex) / 2; i++) {
        unsigned value;
        sscanf(hex + 2 * i, "%2x", &value);
        out[i] = (uint8_t)value;
    }
}

/* Compares a digest with its FIPS or RFC hex vector. */
static void expect_sha256(gw_bytes data, const char *hex) {
    uint8_t digest[32], expected[32];
    assert(gw_sha256(data, (gw_bytes){digest, 32}) == 0);
    hex_to_bytes(hex, expected);
    assert(memcmp(digest, expected, 32) == 0);
}

/* Compares len bytes with a hex string of 2 * len characters. */
static void expect_bytes_hex(const uint8_t *bytes, size_t len, const char *hex) {
    uint8_t expected[128];
    assert(strlen(hex) == 2 * len && len <= sizeof(expected));
    hex_to_bytes(hex, expected);
    assert(memcmp(bytes, expected, len) == 0);
}

static void expect_hmac(gw_bytes key, gw_bytes message, const char *hex) {
    uint8_t tag[32], expected[32];
    assert(gw_hmac_sha256(key, message, (gw_bytes){tag, 32}) == 0);
    hex_to_bytes(hex, expected);
    assert(memcmp(tag, expected, 32) == 0);
}

int main(void) {
    /* FIPS 180-4 SHA-256 vectors: empty, "abc", the 448-bit two-block message, one million 'a'. */
    expect_sha256(text_of(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
    expect_sha256(text_of("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
    expect_sha256(text_of("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
                  "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1");
    static uint8_t million[1000000];
    expect_sha256(repeated(million, sizeof(million), 'a'),
                  "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0");
    /* Wrong output size is refused rather than written. */
    uint8_t small[31];
    assert(gw_sha256(text_of("abc"), (gw_bytes){small, 31}) != 0);

    /* RFC 4231 HMAC-SHA256 test cases 1-4, 6 and 7. */
    uint8_t key1[20], key3[20], key4[25], data3[50], data4[50], key6[131];
    expect_hmac(repeated(key1, 20, 0x0b), text_of("Hi There"),
                "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7");
    expect_hmac(text_of("Jefe"), text_of("what do ya want for nothing?"),
                "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843");
    expect_hmac(repeated(key3, 20, 0xaa), repeated(data3, 50, 0xdd),
                "773ea91e36800e46854db8ebd09181a72959098b3ef8c122d9635514ced565fe");
    for (size_t i = 0; i < sizeof(key4); i++) key4[i] = (uint8_t)(i + 1);
    expect_hmac((gw_bytes){key4, sizeof(key4)}, repeated(data4, 50, 0xcd),
                "82558a389a443c0ea4cc819899f2083a85f0faa3e578f8077a2e3ff46729665b");
    expect_hmac(repeated(key6, 131, 0xaa), text_of("Test Using Larger Than Block-Size Key - Hash Key First"),
                "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54");
    expect_hmac(repeated(key6, 131, 0xaa),
                text_of("This is a test using a larger than block-size key and a larger than block-size data. "
                        "The key needs to be hashed before being used by the HMAC algorithm."),
                "9b09ffa71b942fcb27635fbcd5b0e944bfdc63644f0713938a7f51535c3a35e2");
    /* An empty key is valid; the tag is still 32 bytes. */
    uint8_t empty_tag[32];
    assert(gw_hmac_sha256((gw_bytes){NULL, 0}, text_of("x"), (gw_bytes){empty_tag, 32}) == 0);

    /* Random bytes: two draws differ, and a zero-length request succeeds. */
    uint8_t first[32], second[32];
    assert(gw_random_bytes((gw_bytes){first, 32}) == 1);
    assert(gw_random_bytes((gw_bytes){second, 32}) == 1);
    assert(memcmp(first, second, 32) != 0);
    assert(gw_random_bytes((gw_bytes){NULL, 0}) == 1);

    /* Constant-time comparison: equal, different in one byte, and different lengths. */
    assert(gw_constant_time_equal(text_of("token"), text_of("token")) == 1);
    assert(gw_constant_time_equal(text_of("token"), text_of("tokem")) == 0);
    assert(gw_constant_time_equal(text_of("token"), text_of("toke")) == 0);
    assert(gw_constant_time_equal(text_of(""), text_of("")) == 1);

    /* RFC 4648 section 10 vectors, in the unpadded URL-safe alphabet. */
    static const char *plain[] = {"", "f", "fo", "foo", "foob", "fooba", "foobar"};
    static const char *coded[] = {"", "Zg", "Zm8", "Zm9v", "Zm9vYg", "Zm9vYmE", "Zm9vYmFy"};
    for (size_t i = 0; i < sizeof(plain) / sizeof(plain[0]); i++) {
        uint8_t out[16];
        int64_t n = gw_base64url_encode(text_of(plain[i]), (gw_bytes){out, sizeof(out)});
        assert(n == (int64_t)strlen(coded[i]) && memcmp(out, coded[i], (size_t)n) == 0);
        uint8_t back[16];
        int64_t m = gw_base64url_decode((gw_bytes){out, n}, (gw_bytes){back, sizeof(back)});
        assert(m == (int64_t)strlen(plain[i]) && memcmp(back, plain[i], (size_t)m) == 0);
    }
    /* URL-safe symbols replace '+' and '/': 0xfb 0xff encodes to "-_8" (standard base64 "+/8"). */
    uint8_t high[2] = {0xfb, 0xff};
    uint8_t high_text[8];
    assert(gw_base64url_encode((gw_bytes){high, 2}, (gw_bytes){high_text, 8}) == 3);
    assert(memcmp(high_text, "-_8", 3) == 0);
    uint8_t high_back[2];
    assert(gw_base64url_decode((gw_bytes){(uint8_t *)"-_8", 3}, (gw_bytes){high_back, 2}) == 2);
    assert(high_back[0] == 0xfb && high_back[1] == 0xff);
    /* Encoding refuses an output buffer that is one byte short. */
    uint8_t tight[5];
    assert(gw_base64url_encode(text_of("foobar"), (gw_bytes){tight, 7}) == GW_BASE64URL_ERROR);
    assert(gw_base64url_encode(text_of("foobar"), (gw_bytes){tight, 8}) == 8);
    /* Decoding refuses padding, foreign symbols, impossible lengths, and nonzero unused bits. */
    uint8_t scratch[16];
    assert(gw_base64url_decode(text_of("Zg=="), (gw_bytes){scratch, 16}) == GW_BASE64URL_ERROR);
    assert(gw_base64url_decode(text_of("Zm+v"), (gw_bytes){scratch, 16}) == GW_BASE64URL_ERROR);
    assert(gw_base64url_decode(text_of("Zm9vY"), (gw_bytes){scratch, 16}) == GW_BASE64URL_ERROR);
    assert(gw_base64url_decode(text_of("Zh"), (gw_bytes){scratch, 16}) == GW_BASE64URL_ERROR);
    assert(gw_base64url_decode(text_of("Zm9v"), (gw_bytes){scratch, 2}) == GW_BASE64URL_ERROR);
    assert(gw_base64url_decode(text_of("Zg"), (gw_bytes){scratch, 1}) == 1);

    /* PBKDF2-HMAC-SHA256 (RFC 8018). The RFC 7914 section 11 vector (passwd, salt, c=1, 64 bytes),
       the published vectors for c=1, 2 and 4096, a multi-block case and an embedded-NUL case.
       Expected values were cross-checked against Python hashlib (OpenSSL). */
    uint8_t derived[64];
    assert(gw_pbkdf2_sha256(text_of("passwd"), text_of("salt"), 1, (gw_bytes){derived, 64}) == 0);
    expect_bytes_hex(derived, 64, "55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc"
                                  "49ca9cccf179b645991664b39d77ef317c71b845b1e30bd509112041d3a19783");
    assert(gw_pbkdf2_sha256(text_of("password"), text_of("salt"), 1, (gw_bytes){derived, 32}) == 0);
    expect_bytes_hex(derived, 32, "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b");
    assert(gw_pbkdf2_sha256(text_of("password"), text_of("salt"), 2, (gw_bytes){derived, 32}) == 0);
    expect_bytes_hex(derived, 32, "ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43");
    assert(gw_pbkdf2_sha256(text_of("password"), text_of("salt"), 4096, (gw_bytes){derived, 32}) == 0);
    expect_bytes_hex(derived, 32, "c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a");
    assert(gw_pbkdf2_sha256(text_of("passwordPASSWORDpassword"), text_of("saltSALTsaltSALTsaltSALTsaltSALTsalt"),
                            4096, (gw_bytes){derived, 40}) == 0);
    expect_bytes_hex(derived, 40, "348c89dbcbd32b2f32d814b8116e84cf2b17347ebc1800181c4e2a1fb8dd53e1"
                                  "c635518c7dac47e9");
    /* Embedded NUL bytes are data when the lengths are given: the 9-byte password is not "pass". */
    assert(gw_pbkdf2_sha256((gw_bytes){(uint8_t *)"pass\0word", 9}, (gw_bytes){(uint8_t *)"sa\0lt", 5}, 4096,
                            (gw_bytes){derived, 16}) == 0);
    expect_bytes_hex(derived, 16, "89b69d0516f829893c696226650a8687");
    /* Bad arguments are refused: zero or too many iterations, and empty or oversize output. */
    assert(gw_pbkdf2_sha256(text_of("p"), text_of("s"), 0, (gw_bytes){derived, 32}) == -1);
    assert(gw_pbkdf2_sha256(text_of("p"), text_of("s"), 0x100000000LL, (gw_bytes){derived, 32}) == -1);
    assert(gw_pbkdf2_sha256(text_of("p"), text_of("s"), 1, (gw_bytes){derived, 0}) == -1);
    assert(gw_pbkdf2_sha256(text_of("p"), text_of("s"), 1, (gw_bytes){derived, 1025}) == -1);
    /* A key over one block is hashed first; the result is deterministic and depends on the salt. */
    uint8_t long_key[100], again[32], other[32];
    memset(long_key, 'k', sizeof(long_key));
    assert(gw_pbkdf2_sha256((gw_bytes){long_key, 100}, text_of("salt"), 3, (gw_bytes){again, 32}) == 0);
    assert(gw_pbkdf2_sha256((gw_bytes){long_key, 100}, text_of("salt"), 3, (gw_bytes){other, 32}) == 0);
    assert(memcmp(again, other, 32) == 0);
    assert(gw_pbkdf2_sha256((gw_bytes){long_key, 100}, text_of("salt2"), 3, (gw_bytes){other, 32}) == 0);
    assert(memcmp(again, other, 32) != 0);

    puts("Crypto tests passed: FIPS 180-4 SHA-256, RFC 4231 HMAC cases 1-4, 6, 7, PBKDF2-HMAC-SHA256 "
         "(RFC 7914 and published vectors), random bytes, constant-time compare, strict base64url");
    return 0;
}
