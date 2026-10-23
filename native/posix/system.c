/* Filesystem, environment and clock calls for the framework. Each function borrows its
   arguments for the call only and retains no Goose pointers. Paths and names are copied
   into fixed C buffers so they can be NUL-terminated; longer inputs are refused. */
#define _POSIX_C_SOURCE 200809L
#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>
#include <sys/stat.h>
#include "constants.h"

typedef struct { uint8_t *data; int64_t len; } gw_bytes;

/* Copies a Goose byte slice into a NUL-terminated buffer. Refuses embedded NUL bytes. */
static int gw_copy_text(gw_bytes text, char *out, size_t capacity) {
    if (text.len < 0 || (uint64_t)text.len >= capacity) return 0;
    if (text.len > 0) memcpy(out, text.data, (size_t)text.len);
    out[text.len] = '\0';
    return memchr(out, '\0', (size_t)text.len) == NULL;
}

/* Kind of the entry at path, following symlinks. Size is set only for regular files. */
int32_t gw_file_stat(gw_bytes path, int64_t *size) {
    char name[GW_PATH_MAX_BYTES];
    struct stat info;
    *size = 0;
    if (!gw_copy_text(path, name, sizeof(name))) return GW_FILE_ERROR;
    if (stat(name, &info) != 0) {
        return errno == ENOENT || errno == ENOTDIR ? GW_FILE_MISSING : GW_FILE_ERROR;
    }
    if (S_ISREG(info.st_mode)) {
        *size = (int64_t)info.st_size;
        return GW_FILE_REGULAR;
    }
    if (S_ISDIR(info.st_mode)) return GW_FILE_DIRECTORY;
    return GW_FILE_OTHER;
}

/* Reads at most buffer.len bytes of a regular file into buffer and returns the count.
   Opening is nonblocking and the file type is checked before reading, so a FIFO cannot
   stall the reactor. Returns GW_IO_ERROR for a missing, unreadable or non-regular file. */
int64_t gw_file_read(gw_bytes path, gw_bytes buffer) {
    char name[GW_PATH_MAX_BYTES];
    struct stat info;
    if (buffer.len < 0 || !gw_copy_text(path, name, sizeof(name))) return GW_IO_ERROR;
    int fd = open(name, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) return GW_IO_ERROR;
    if (fstat(fd, &info) != 0 || !S_ISREG(info.st_mode)) {
        close(fd);
        return GW_IO_ERROR;
    }
    int64_t total = 0;
    while (total < buffer.len) {
        ssize_t n = read(fd, buffer.data + total, (size_t)(buffer.len - total));
        if (n == 0) break;
        if (n < 0) {
            if (errno == EINTR) continue;
            close(fd);
            return GW_IO_ERROR;
        }
        total += (int64_t)n;
    }
    close(fd);
    return total;
}

/* Copies the value of an environment variable into value. Returns its length, GW_ENV_UNSET
   when the variable is absent, or GW_ENV_TOO_LONG when it does not fit. */
int64_t gw_getenv(gw_bytes name, gw_bytes value) {
    char key[GW_ENV_NAME_MAX_BYTES];
    if (value.len < 0 || !gw_copy_text(name, key, sizeof(key))) return GW_ENV_UNSET;
    const char *text = getenv(key);
    if (text == NULL) return GW_ENV_UNSET;
    size_t length = strlen(text);
    if (length > (size_t)value.len) return GW_ENV_TOO_LONG;
    if (length > 0) memcpy(value.data, text, length);
    return (int64_t)length;
}

/* Monotonic nanoseconds for deadlines. */
int64_t gw_clock_ns(void) {
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) return 0;
    return (int64_t)now.tv_sec * 1000000000 + (int64_t)now.tv_nsec;
}
