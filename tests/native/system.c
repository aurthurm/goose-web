#include "../../native/posix/system.c"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static gw_bytes text_of(const char *s) { return (gw_bytes){(uint8_t *)s, (int64_t)strlen(s)}; }

/* out = base + "/" + name, refusing a result that does not fit. */
static void join_path(char *out, size_t capacity, const char *base, const char *name) {
    size_t base_length = strlen(base);
    size_t name_length = strlen(name);
    assert(base_length + 1 + name_length < capacity);
    memcpy(out, base, base_length);
    out[base_length] = '/';
    memcpy(out + base_length + 1, name, name_length + 1);
}

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

    /* Wall clock: after 2020-01-01 and not behind the previous reading. */
    int64_t unix_first = gw_unix_seconds();
    assert(unix_first > 1577836800 && gw_unix_seconds() >= unix_first);

    /* Containment: a path is inside a root when its real location (links resolved) is the root or
       below it. A link inside the root to a file inside it stays inside; a link to a file outside is
       refused; a sibling whose name starts with the root's name is outside. */
    enum { CONTAIN_PATH = 2 * GW_PATH_MAX_BYTES };
    char inside[CONTAIN_PATH], outside[CONTAIN_PATH], sibling[CONTAIN_PATH], inner_file[CONTAIN_PATH];
    char link_in[CONTAIN_PATH], link_out[CONTAIN_PATH], target_out[CONTAIN_PATH], sibling_file[CONTAIN_PATH];
    char absent_file[CONTAIN_PATH];
    join_path(inside, sizeof(inside), dir, "inside");
    join_path(outside, sizeof(outside), dir, "outside");
    join_path(sibling, sizeof(sibling), dir, "inside-sibling");
    join_path(inner_file, sizeof(inner_file), inside, "file.txt");
    join_path(link_in, sizeof(link_in), inside, "link_in");
    join_path(link_out, sizeof(link_out), inside, "link_out");
    join_path(target_out, sizeof(target_out), outside, "secret.txt");
    join_path(sibling_file, sizeof(sibling_file), sibling, "f");
    join_path(absent_file, sizeof(absent_file), inside, "absent");
    assert(mkdir(inside, 0700) == 0 && mkdir(outside, 0700) == 0 && mkdir(sibling, 0700) == 0);
    FILE *inner = fopen(inner_file, "wb");
    FILE *secret = fopen(target_out, "wb");
    FILE *other = fopen(sibling_file, "wb");
    assert(inner != NULL && secret != NULL && other != NULL);
    fputs("in", inner);
    fputs("secret", secret);
    fputs("sibling", other);
    fclose(inner);
    fclose(secret);
    fclose(other);
    assert(symlink(inner_file, link_in) == 0 && symlink(target_out, link_out) == 0);
    assert(gw_file_within(text_of(inside), text_of(inner_file)) == 1);
    assert(gw_file_within(text_of(inside), text_of(inside)) == 1);
    assert(gw_file_within(text_of(inside), text_of(link_in)) == 1);
    assert(gw_file_within(text_of(inside), text_of(link_out)) == 0);
    assert(gw_file_within(text_of(inside), text_of(target_out)) == 0);
    assert(gw_file_within(text_of(inside), text_of(sibling_file)) == 0);
    assert(gw_file_within(text_of(inside), text_of(absent_file)) == GW_FILE_ERROR);
    assert(gw_file_within(text_of("/"), text_of(inner_file)) == 1);
    assert(gw_file_within(text_of(inside), (gw_bytes){NULL, 0}) == GW_FILE_ERROR);
    assert(unlink(link_out) == 0 && unlink(link_in) == 0 && unlink(sibling_file) == 0 && unlink(target_out) == 0);
    assert(unlink(inner_file) == 0 && rmdir(sibling) == 0 && rmdir(outside) == 0 && rmdir(inside) == 0);

    assert(unlink(fifo) == 0 && unlink(file) == 0 && rmdir(dir) == 0);
    puts("System tests passed: file kinds and sizes, bounded reads, FIFO refusal, environment, clocks");
    return 0;
}
