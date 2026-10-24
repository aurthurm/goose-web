/* libFuzzer harness for the byte-slice primitives in native/posix/crypto.c: strict base64url decode
   and encode, HMAC-SHA256 and PBKDF2 on arbitrary keys. Outputs are exact-size heap buffers, so
   AddressSanitizer reports any write past what the function was given. Requires clang (see
   tests/run.py for the detection and the bounded run):

     clang -std=c11 -g -O1 -fsanitize=fuzzer,address tests/fuzz/native/codec_fuzz.c -o build/codec_fuzz
     build/codec_fuzz -max_total_time=60 -artifact_prefix=build/ */
#include "../../../native/posix/crypto.c"
#include <assert.h>
#include <stdlib.h>
#include <string.h>

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    /* Decode: a canonical text decodes to bytes, and encoding those bytes gives the text back. */
    size_t decode_cap = size / 4 * 3 + 3;
    uint8_t *decoded = malloc(decode_cap);
    assert(decoded != NULL);
    int64_t n = gw_base64url_decode((gw_bytes){(uint8_t *)data, (int64_t)size}, (gw_bytes){decoded, (int64_t)decode_cap});
    assert(n < 0 || n <= (int64_t)decode_cap);
    if (n >= 0) {
        size_t encode_cap = ((size_t)n * 4 + 2) / 3;
        uint8_t *text = malloc(encode_cap == 0 ? 1 : encode_cap);
        assert(text != NULL);
        int64_t m = gw_base64url_encode((gw_bytes){decoded, n}, (gw_bytes){text, (int64_t)encode_cap});
        assert(m == (int64_t)size && (size == 0 || memcmp(text, data, size) == 0));
        free(text);
    }
    free(decoded);

    /* Encode arbitrary bytes into an exact buffer; the result decodes back to the same bytes. */
    size_t encoded_cap = (size * 4 + 2) / 3;
    uint8_t *encoded = malloc(encoded_cap == 0 ? 1 : encoded_cap);
    assert(encoded != NULL);
    int64_t e = gw_base64url_encode((gw_bytes){(uint8_t *)data, (int64_t)size}, (gw_bytes){encoded, (int64_t)encoded_cap});
    assert(e == (int64_t)encoded_cap);
    uint8_t *back = malloc(size == 0 ? 1 : size);
    assert(back != NULL);
    int64_t b = gw_base64url_decode((gw_bytes){encoded, e}, (gw_bytes){back, (int64_t)size});
    assert(b == (int64_t)size && (size == 0 || memcmp(back, data, size) == 0));
    free(back);
    free(encoded);

    /* Keyed primitives: the first byte picks a key length, the rest is the message. Tags are fixed
       size, and PBKDF2 with 1 to 3 iterations stays cheap. */
    if (size > 0) {
        /* The key is 0..size-1 bytes, so the message after it is never negative. */
        size_t body = size - 1;
        size_t key_len = body == 0 ? 0 : data[0] % (body + 1);
        gw_bytes key = {(uint8_t *)data + 1, (int64_t)key_len};
        gw_bytes message = {(uint8_t *)data + 1 + key_len, (int64_t)(body - key_len)};
        uint8_t tag[32], derived[48];
        assert(gw_hmac_sha256(key, message, (gw_bytes){tag, 32}) == 0);
        assert(gw_pbkdf2_sha256(key, message, 1 + (int64_t)(data[0] % 3), (gw_bytes){derived, 48}) == 0);
    }
    return 0;
}
