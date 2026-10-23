#include "../../native/posix/system.c"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static gw_bytes text_of(const char *s) { return (gw_bytes){(uint8_t *)s, (int64_t)strlen(s)}; }

int main(void) {
    char dir[] = "/tmp/gw-system-XXXXXX";
    assert(mkdtemp(dir) != NULL);
    char file[1024], fifo[1024], big[GW_PATH_MAX_BYTES + 16];
    snprintf(file, sizeof(file), "%s/data.txt", dir);
    snprintf(fifo, sizeof(fifo), "%s/pipe", dir);
    FILE *out = fopen(file, "wb");
    assert(out != NULL);
    fputs("0123456789", out);
    fclose(out);
    assert(mkfifo(fifo, 0600) == 0);

    /* Kinds: regular file with size, directory, missing, FIFO is "other", bad paths are errors. */
    int64_t size = -7;
    assert(gw_file_stat(text_of(file), &size) == GW_FILE_REGULAR && size == 10);
    assert(gw_file_stat(text_of(dir), &size) == GW_FILE_DIRECTORY && size == 0);
    assert(gw_file_stat(text_of(fifo), &size) == GW_FILE_OTHER && size == 0);
    snprintf(big, sizeof(big), "%s/absent", dir);
    assert(gw_file_stat(text_of(big), &size) == GW_FILE_MISSING && size == 0);
    char below_file[GW_PATH_MAX_BYTES + 16];
    snprintf(below_file, sizeof(below_file), "%s/x", file);
    assert(gw_file_stat(text_of(below_file), &size) == GW_FILE_MISSING);
    memset(big, 'a', sizeof(big) - 1);
    big[sizeof(big) - 1] = '\0';
    assert(gw_file_stat(text_of(big), &size) == GW_FILE_ERROR);
    char nul_path[] = "a\0b";
    assert(gw_file_stat((gw_bytes){(uint8_t *)nul_path, 3}, &size) == GW_FILE_ERROR);

    /* Bounded reads: never more than the buffer, whole files when they fit, and refusals. */
    uint8_t small[4];
    assert(gw_file_read(text_of(file), (gw_bytes){small, sizeof(small)}) == 4);
    assert(memcmp(small, "0123", 4) == 0);
    uint8_t whole[64];
    assert(gw_file_read(text_of(file), (gw_bytes){whole, sizeof(whole)}) == 10);
    assert(memcmp(whole, "0123456789", 10) == 0);
    assert(gw_file_read(text_of(dir), (gw_bytes){whole, sizeof(whole)}) == GW_IO_ERROR);
    assert(gw_file_read(text_of(fifo), (gw_bytes){whole, sizeof(whole)}) == GW_IO_ERROR);
    assert(gw_file_read(text_of(big), (gw_bytes){whole, sizeof(whole)}) == GW_IO_ERROR);

    /* Environment: unset, copied, and too long for the buffer. */
    unsetenv("GW_SYSTEM_TEST");
    uint8_t value[8];
    assert(gw_getenv(text_of("GW_SYSTEM_TEST"), (gw_bytes){value, sizeof(value)}) == GW_ENV_UNSET);
    setenv("GW_SYSTEM_TEST", "hello", 1);
    assert(gw_getenv(text_of("GW_SYSTEM_TEST"), (gw_bytes){value, sizeof(value)}) == 5);
    assert(memcmp(value, "hello", 5) == 0);
    assert(gw_getenv(text_of("GW_SYSTEM_TEST"), (gw_bytes){value, 2}) == GW_ENV_TOO_LONG);
    setenv("GW_SYSTEM_TEST", "", 1);
    assert(gw_getenv(text_of("GW_SYSTEM_TEST"), (gw_bytes){value, sizeof(value)}) == 0);
    unsetenv("GW_SYSTEM_TEST");

    /* Monotonic clock never goes backwards. */
    int64_t first = gw_clock_ns();
    int64_t second = gw_clock_ns();
    assert(first > 0 && second >= first);

    assert(unlink(fifo) == 0 && unlink(file) == 0 && rmdir(dir) == 0);
    puts("System tests passed: file kinds and sizes, bounded reads, FIFO refusal, environment, monotonic clock");
    return 0;
}
