/* The transport owns no application state and retains no Goose pointers.
   Status: -2 = would block/interrupted, -1 = fatal, 0 = EOF for reads. */
#define _POSIX_C_SOURCE 200809L
#include <stdint.h>
#include <stddef.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include "constants.h"

typedef struct { uint8_t *data; int64_t len; } gw_bytes;
typedef struct { int32_t *data; int64_t len; } gw_ints;

static int gw_nonblock(int fd) {
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0 ||
        fcntl(fd, F_SETFD, FD_CLOEXEC) < 0) { close(fd); return GW_INVALID_SOCKET; }
#ifdef SO_NOSIGPIPE
    int one = 1;
    if (setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one)) < 0) {
        close(fd); return GW_INVALID_SOCKET;
    }
#endif
    return fd;
}

int32_t gw_listen_config(int32_t port, int32_t public_bind) {
    if (port < GW_MIN_PORT || port > GW_MAX_PORT ||
        (public_bind != GW_BIND_LOOPBACK && public_bind != GW_BIND_PUBLIC)) return GW_INVALID_SOCKET;
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return GW_INVALID_SOCKET;
    int one = 1;
    if (setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one)) < 0) {
        close(fd); return GW_INVALID_SOCKET;
    }
    struct sockaddr_in addr = {0};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(public_bind ? INADDR_ANY : INADDR_LOOPBACK);
    addr.sin_port = htons((uint16_t)port);
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0 || listen(fd, GW_SOCKET_BACKLOG) < 0) {
        close(fd); return GW_INVALID_SOCKET;
    }
    return gw_nonblock(fd);
}

int32_t gw_accept(int32_t listener) {
    int fd = accept(listener, NULL, NULL);
    if (fd >= 0) return gw_nonblock(fd);
    return errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR ? GW_IO_WOULD_BLOCK : GW_IO_ERROR;
}

/* Writes the peer's numeric address (IPv4 or IPv6 text) into out. Returns its length, or -1. */
int64_t gw_peer_address(int32_t fd, gw_bytes out) {
    struct sockaddr_storage peer;
    socklen_t length = sizeof(peer);
    if (getpeername(fd, (struct sockaddr *)&peer, &length) < 0) return -1;
    const void *address;
    if (peer.ss_family == AF_INET) address = &((struct sockaddr_in *)&peer)->sin_addr;
    else if (peer.ss_family == AF_INET6) address = &((struct sockaddr_in6 *)&peer)->sin6_addr;
    else return -1;
    char text[INET6_ADDRSTRLEN];
    if (inet_ntop(peer.ss_family, address, text, sizeof(text)) == NULL) return -1;
    size_t n = strlen(text);
    if ((int64_t)n > out.len) return -1;
    memcpy(out.data, text, n);
    return (int64_t)n;
}

int64_t gw_recv(int32_t fd, gw_bytes bytes) {
    ssize_t n = recv(fd, bytes.data, (size_t)bytes.len, 0);
    if (n >= 0) return n;
    return errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR ? GW_IO_WOULD_BLOCK : GW_IO_ERROR;
}

int64_t gw_send(int32_t fd, gw_bytes bytes) {
#ifdef MSG_NOSIGNAL
    ssize_t n = send(fd, bytes.data, (size_t)bytes.len, MSG_NOSIGNAL);
#else
    ssize_t n = send(fd, bytes.data, (size_t)bytes.len, 0);
#endif
    if (n >= 0) return n;
    return errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR ? GW_IO_WOULD_BLOCK : GW_IO_ERROR;
}

/* Per-call poll state: one listener plus the bounded client pool. */
int32_t gw_poll(gw_ints fds, gw_ints interests, gw_ints ready, int32_t timeout) {
    if (fds.len > GW_MAX_POLL_FDS || interests.len != fds.len || ready.len != fds.len) return GW_IO_ERROR;
    struct pollfd items[GW_MAX_POLL_FDS];
    for (int64_t i = 0; i < fds.len; ++i) {
        items[i].fd = fds.data[i];
        items[i].events = interests.data[i] == GW_POLL_WRITE ? POLLOUT : POLLIN;
        items[i].revents = 0;
        ready.data[i] = 0;
    }
    int n = poll(items, (nfds_t)fds.len, timeout);
    if (n < 0) return errno == EINTR ? 0 : GW_IO_ERROR;
    for (int64_t i = 0; i < fds.len; ++i) {
        short r = items[i].revents;
        /* HUP may accompany readable buffered data. Try read/write first. */
        ready.data[i] = (r & (POLLIN | POLLOUT | POLLHUP)) ? 1 :
                       (r & (POLLERR | POLLNVAL)) ? GW_IO_ERROR : 0;
    }
    return n;
}

void gw_close(int32_t fd) { if (fd >= 0) close(fd); }

int64_t gw_transport_max_clients(void) { return GW_MAX_CLIENTS; }

int32_t gw_listen(int32_t port) { return gw_listen_config(port, GW_BIND_LOOPBACK); }

/* Opt-in process-wide ownership. The signal handler only writes sig_atomic_t.
   Call begin/end from one reactor thread; nested ownership is rejected.
   Embedders using other threads should manage signals externally instead. */
static volatile sig_atomic_t gw_stop_signal;
static int gw_signals_owned;
static struct sigaction gw_old_int, gw_old_term;
static void gw_stop_handler(int signal_number) { gw_stop_signal = signal_number; }
int32_t gw_signals_begin(void) {
    if (gw_signals_owned) return -1;
    struct sigaction action = {0};
    action.sa_handler = gw_stop_handler;
    sigemptyset(&action.sa_mask);
    gw_stop_signal = 0;
    if (sigaction(SIGINT, &action, &gw_old_int) < 0) return -1;
    if (sigaction(SIGTERM, &action, &gw_old_term) < 0) {
        sigaction(SIGINT, &gw_old_int, NULL);
        return -1;
    }
    gw_signals_owned = 1;
    return 0;
}
int32_t gw_signal_pending(void) { return gw_stop_signal; }
void gw_signals_end(void) {
    if (!gw_signals_owned) return;
    sigaction(SIGINT, &gw_old_int, NULL);
    sigaction(SIGTERM, &gw_old_term, NULL);
    gw_signals_owned = 0;
}
