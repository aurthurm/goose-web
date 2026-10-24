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

#if defined(__linux__) && !defined(GW_REACTOR_POLL)
#include <sys/epoll.h>
#define GW_REACTOR_EPOLL 1
#else
#define GW_REACTOR_EPOLL 0
#endif

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
    /* A negative length would wrap to a huge size_t; refuse it before the call. */
    if (bytes.len < 0 || (bytes.len > 0 && bytes.data == NULL)) return GW_IO_ERROR;
    ssize_t n = recv(fd, bytes.data, (size_t)bytes.len, 0);
    if (n >= 0) return n;
    return errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR ? GW_IO_WOULD_BLOCK : GW_IO_ERROR;
}

int64_t gw_send(int32_t fd, gw_bytes bytes) {
    if (bytes.len < 0 || (bytes.len > 0 && bytes.data == NULL)) return GW_IO_ERROR;
#ifdef MSG_NOSIGNAL
    ssize_t n = send(fd, bytes.data, (size_t)bytes.len, MSG_NOSIGNAL);
#else
    ssize_t n = send(fd, bytes.data, (size_t)bytes.len, 0);
#endif
    if (n >= 0) return n;
    return errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR ? GW_IO_WOULD_BLOCK : GW_IO_ERROR;
}

/* Readiness reactor. Each descriptor is registered once under a token (a connection slot, or
   the listener at GW_MAX_POLL_FDS - 1) and its interest is changed only when it changes: read
   to write and back. Descriptors are removed before they close. Linux uses level-triggered
   epoll; other systems, and builds with -DGW_REACTOR_POLL, poll the same table. One reactor
   is open per process. */
typedef struct { int32_t fd; int32_t write; int32_t active; } gw_registration;
static gw_registration gw_regs[GW_MAX_POLL_FDS];
static int gw_reactor_is_open;
#if GW_REACTOR_EPOLL
static int gw_epoll_fd = -1;
#endif

static int gw_token_valid(int32_t token) { return token >= 0 && token < GW_MAX_POLL_FDS; }

int32_t gw_reactor_open(void) {
    if (gw_reactor_is_open) return GW_IO_ERROR;
#if GW_REACTOR_EPOLL
    gw_epoll_fd = epoll_create1(EPOLL_CLOEXEC);
    if (gw_epoll_fd < 0) return GW_IO_ERROR;
#endif
    memset(gw_regs, 0, sizeof(gw_regs));
    gw_reactor_is_open = 1;
    return 0;
}

void gw_reactor_close(void) {
    if (!gw_reactor_is_open) return;
#if GW_REACTOR_EPOLL
    close(gw_epoll_fd);
    gw_epoll_fd = -1;
#endif
    memset(gw_regs, 0, sizeof(gw_regs));
    gw_reactor_is_open = 0;
}

/* Registers fd under token with read interest, or write interest when write is nonzero. */
int32_t gw_reactor_add(int32_t token, int32_t fd, int32_t write) {
    if (!gw_reactor_is_open || !gw_token_valid(token) || fd < 0 || gw_regs[token].active) return GW_IO_ERROR;
#if GW_REACTOR_EPOLL
    struct epoll_event event;
    memset(&event, 0, sizeof(event));
    event.events = write ? EPOLLOUT : EPOLLIN;
    event.data.u32 = (uint32_t)token;
    if (epoll_ctl(gw_epoll_fd, EPOLL_CTL_ADD, fd, &event) < 0) return GW_IO_ERROR;
#endif
    gw_regs[token].fd = fd;
    gw_regs[token].write = write ? 1 : 0;
    gw_regs[token].active = 1;
    return 0;
}

/* Switches a registered descriptor between read and write interest. Nothing changes when the
   interest already matches, so callers may call this every iteration. */
int32_t gw_reactor_modify(int32_t token, int32_t fd, int32_t write) {
    if (!gw_reactor_is_open || !gw_token_valid(token) || !gw_regs[token].active || gw_regs[token].fd != fd) {
        return GW_IO_ERROR;
    }
    int32_t want = write ? 1 : 0;
    if (gw_regs[token].write == want) return 0;
#if GW_REACTOR_EPOLL
    struct epoll_event event;
    memset(&event, 0, sizeof(event));
    event.events = want ? EPOLLOUT : EPOLLIN;
    event.data.u32 = (uint32_t)token;
    if (epoll_ctl(gw_epoll_fd, EPOLL_CTL_MOD, fd, &event) < 0) return GW_IO_ERROR;
#endif
    gw_regs[token].write = want;
    return 0;
}

/* Unregisters token when it holds fd. Unknown or mismatched registrations are ignored. */
void gw_reactor_remove(int32_t token, int32_t fd) {
    if (!gw_reactor_is_open || !gw_token_valid(token) || !gw_regs[token].active || gw_regs[token].fd != fd) return;
#if GW_REACTOR_EPOLL
    (void)epoll_ctl(gw_epoll_fd, EPOLL_CTL_DEL, fd, NULL);
#endif
    memset(&gw_regs[token], 0, sizeof(gw_regs[token]));
}

/* Waits up to timeout milliseconds. Writes each ready token into tokens and its state into ready
   (1 readable or writable, -1 error), and returns how many were written, or -1 on failure. */
int32_t gw_reactor_wait(gw_ints tokens, gw_ints ready, int32_t timeout) {
    if (!gw_reactor_is_open || tokens.len < GW_MAX_POLL_FDS || ready.len < GW_MAX_POLL_FDS) return GW_IO_ERROR;
    int32_t count = 0;
#if GW_REACTOR_EPOLL
    struct epoll_event events[GW_MAX_POLL_FDS];
    int n = epoll_wait(gw_epoll_fd, events, GW_MAX_POLL_FDS, timeout);
    if (n < 0) return errno == EINTR ? 0 : GW_IO_ERROR;
    for (int i = 0; i < n; ++i) {
        uint32_t bits = events[i].events;
        /* HUP may accompany readable buffered data. Try read/write first. */
        int32_t state = (bits & (EPOLLIN | EPOLLOUT | EPOLLHUP)) ? 1 : (bits & EPOLLERR) ? GW_IO_ERROR : 0;
        if (state == 0) continue;
        tokens.data[count] = (int32_t)events[i].data.u32;
        ready.data[count] = state;
        ++count;
    }
#else
    struct pollfd items[GW_MAX_POLL_FDS];
    int32_t owners[GW_MAX_POLL_FDS];
    nfds_t n = 0;
    for (int32_t token = 0; token < GW_MAX_POLL_FDS; ++token) {
        if (!gw_regs[token].active) continue;
        items[n].fd = gw_regs[token].fd;
        items[n].events = gw_regs[token].write ? POLLOUT : POLLIN;
        items[n].revents = 0;
        owners[n] = token;
        ++n;
    }
    if (poll(items, n, timeout) < 0) return errno == EINTR ? 0 : GW_IO_ERROR;
    for (nfds_t i = 0; i < n; ++i) {
        short bits = items[i].revents;
        /* HUP may accompany readable buffered data. Try read/write first. */
        int32_t state = (bits & (POLLIN | POLLOUT | POLLHUP)) ? 1 : (bits & (POLLERR | POLLNVAL)) ? GW_IO_ERROR : 0;
        if (state == 0) continue;
        tokens.data[count] = owners[i];
        ready.data[count] = state;
        ++count;
    }
#endif
    return count;
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
