/* Experimental POSIX socket shim. Not a complete HTTP implementation.
 * Accepts only loopback connections to reduce accidental public exposure.
 * Slice representation follows Goose's documented C ABI (ptr, int64 length).
 */
#if defined(_WIN32)
#error "POSIX prototype only; implement Windows adapter before enabling."
#endif
#include <stdint.h>
#include <stddef.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <unistd.h>
#include <string.h>
#include <errno.h>

typedef struct { uint8_t *data; int64_t len; } gw_slice;
typedef struct { const uint8_t *data; int64_t len; } gw_const_slice;

int32_t gw_listen(int32_t port) {
    if (port < 1 || port > 65535) return -1;
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof yes);
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof addr);
    addr.sin_family = AF_INET;
    addr.sin_port = htons((uint16_t)port);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(fd, (struct sockaddr *)&addr, sizeof addr) != 0 || listen(fd, 64) != 0) {
        close(fd); return -1;
    }
    return fd;
}
int32_t gw_accept(int32_t listener) { return accept(listener, NULL, NULL); }
int64_t gw_read(int32_t client, gw_slice data) {
    if (data.len <= 0 || data.len > 8192 || !data.data) return -1;
    ssize_t n;
    do { n = recv(client, data.data, (size_t)data.len, 0); } while (n < 0 && errno == EINTR);
    return (int64_t)n;
}
int64_t gw_write(int32_t client, gw_const_slice data) {
    if (data.len <= 0 || !data.data) return -1;
    ssize_t n;
#ifdef MSG_NOSIGNAL
    do { n = send(client, data.data, (size_t)data.len, MSG_NOSIGNAL); } while (n < 0 && errno == EINTR);
#else
    do { n = send(client, data.data, (size_t)data.len, 0); } while (n < 0 && errno == EINTR);
#endif
    return (int64_t)n;
}
void gw_close(int32_t fd) { if (fd >= 0) close(fd); }
