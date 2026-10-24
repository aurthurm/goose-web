/* TCP client calls and a readiness instance for the custom-protocol TCP layer (src/net/tcp.goose).
   It is separate from transport.c, whose reactor is fixed at the HTTP connection limit: this one
   holds up to GW_TCP_MAX_TOKENS descriptors, one token per connection slot. Listening and
   accept/recv/send reuse transport.c. The functions borrow their arguments for the call only and
   retain no Goose pointers. Status: -2 = would block, -1 = fatal. */
#define _POSIX_C_SOURCE 200809L
#include <stdint.h>
#include <stddef.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>

#if defined(__linux__) && !defined(GW_REACTOR_POLL)
#include <sys/epoll.h>
#define GW_TCP_EPOLL 1
#else
#define GW_TCP_EPOLL 0
#endif

/* Mirror src/constants/tcp.goose: token 0 is the listener, slot i is token i + 1. */
#define GW_TCP_MAX_TOKENS 1025
#define GW_TCP_INTEREST_READ 1
#define GW_TCP_INTEREST_WRITE 2
#define GW_TCP_FAILED (-1)
#define GW_TCP_HOST_MAX_BYTES 64

typedef struct { uint8_t *data; int64_t len; } gw_tcp_bytes;
typedef struct { int32_t *data; int64_t len; } gw_tcp_ints;

typedef struct { int32_t fd; int32_t interest; int32_t active; } gw_tcp_registration;
static gw_tcp_registration gw_tcp_regs[GW_TCP_MAX_TOKENS];
static int gw_tcp_open_flag;
static int32_t gw_tcp_capacity;
#if GW_TCP_EPOLL
static int gw_tcp_epoll_fd = -1;

static uint32_t gw_tcp_event_bits(int32_t interest) {
    uint32_t bits = 0;
    if (interest & GW_TCP_INTEREST_READ) bits |= EPOLLIN;
    if (interest & GW_TCP_INTEREST_WRITE) bits |= EPOLLOUT;
    return bits;
}
#endif

/* Opens the readiness instance for up to capacity tokens (1..GW_TCP_MAX_TOKENS). It is independent
   of transport.c's reactor, so a process may hold both. */
int32_t gw_tcp_reactor_open(int32_t capacity) {
    if (gw_tcp_open_flag || capacity < 1 || capacity > GW_TCP_MAX_TOKENS) return GW_TCP_FAILED;
#if GW_TCP_EPOLL
    gw_tcp_epoll_fd = epoll_create1(EPOLL_CLOEXEC);
    if (gw_tcp_epoll_fd < 0) return GW_TCP_FAILED;
#endif
    memset(gw_tcp_regs, 0, sizeof(gw_tcp_regs));
    gw_tcp_capacity = capacity;
    gw_tcp_open_flag = 1;
    return 0;
}

void gw_tcp_reactor_close(void) {
    if (!gw_tcp_open_flag) return;
#if GW_TCP_EPOLL
    close(gw_tcp_epoll_fd);
    gw_tcp_epoll_fd = -1;
#endif
    memset(gw_tcp_regs, 0, sizeof(gw_tcp_regs));
    gw_tcp_open_flag = 0;
}

static int gw_tcp_token_ok(int32_t token) {
    return gw_tcp_open_flag && token >= 0 && token < gw_tcp_capacity;
}

/* Registers fd under token with the given interest (bit 1 read, bit 2 write, 0 none). */
int32_t gw_tcp_add(int32_t token, int32_t fd, int32_t interest) {
    if (!gw_tcp_token_ok(token) || fd < 0 || gw_tcp_regs[token].active) return GW_TCP_FAILED;
    if ((interest & ~3) != 0) return GW_TCP_FAILED;
#if GW_TCP_EPOLL
    struct epoll_event event;
    memset(&event, 0, sizeof(event));
    event.events = gw_tcp_event_bits(interest);
    event.data.u32 = (uint32_t)token;
    if (epoll_ctl(gw_tcp_epoll_fd, EPOLL_CTL_ADD, fd, &event) < 0) return GW_TCP_FAILED;
#endif
    gw_tcp_regs[token].fd = fd;
    gw_tcp_regs[token].interest = interest;
    gw_tcp_regs[token].active = 1;
    return 0;
}

/* Changes the interest of a registered descriptor. Unchanged interest makes no kernel call. */
int32_t gw_tcp_set_interest(int32_t token, int32_t fd, int32_t interest) {
    if (!gw_tcp_token_ok(token) || !gw_tcp_regs[token].active || gw_tcp_regs[token].fd != fd) return GW_TCP_FAILED;
    if ((interest & ~3) != 0) return GW_TCP_FAILED;
    if (gw_tcp_regs[token].interest == interest) return 0;
#if GW_TCP_EPOLL
    struct epoll_event event;
    memset(&event, 0, sizeof(event));
    event.events = gw_tcp_event_bits(interest);
    event.data.u32 = (uint32_t)token;
    if (epoll_ctl(gw_tcp_epoll_fd, EPOLL_CTL_MOD, fd, &event) < 0) return GW_TCP_FAILED;
#endif
    gw_tcp_regs[token].interest = interest;
    return 0;
}

/* Unregisters token when it holds fd. Call before the descriptor closes. */
void gw_tcp_remove(int32_t token, int32_t fd) {
    if (!gw_tcp_token_ok(token) || !gw_tcp_regs[token].active || gw_tcp_regs[token].fd != fd) return;
#if GW_TCP_EPOLL
    (void)epoll_ctl(gw_tcp_epoll_fd, EPOLL_CTL_DEL, fd, NULL);
#endif
    memset(&gw_tcp_regs[token], 0, sizeof(gw_tcp_regs[token]));
}

/* Waits up to timeout ms. Writes each ready token and its state (1 ready, -1 error) and returns
   the count. Hangups and errors are reported whatever the interest, as the kernel reports them. */
int32_t gw_tcp_wait(gw_tcp_ints tokens, gw_tcp_ints ready, int32_t timeout) {
    if (!gw_tcp_open_flag || tokens.len < gw_tcp_capacity || ready.len < gw_tcp_capacity) return GW_TCP_FAILED;
    int32_t count = 0;
#if GW_TCP_EPOLL
    struct epoll_event events[GW_TCP_MAX_TOKENS];
    int n = epoll_wait(gw_tcp_epoll_fd, events, gw_tcp_capacity, timeout);
    if (n < 0) return errno == EINTR ? 0 : GW_TCP_FAILED;
    for (int i = 0; i < n; ++i) {
        uint32_t bits = events[i].events;
        int32_t state = (bits & (EPOLLIN | EPOLLOUT | EPOLLHUP)) ? 1 : (bits & EPOLLERR) ? GW_TCP_FAILED : 0;
        if (state == 0) continue;
        tokens.data[count] = (int32_t)events[i].data.u32;
        ready.data[count] = state;
        ++count;
    }
#else
    struct pollfd items[GW_TCP_MAX_TOKENS];
    int32_t owners[GW_TCP_MAX_TOKENS];
    nfds_t n = 0;
    for (int32_t token = 0; token < gw_tcp_capacity; ++token) {
        if (!gw_tcp_regs[token].active) continue;
        items[n].fd = gw_tcp_regs[token].fd;
        items[n].events = 0;
        if (gw_tcp_regs[token].interest & GW_TCP_INTEREST_READ) items[n].events |= POLLIN;
        if (gw_tcp_regs[token].interest & GW_TCP_INTEREST_WRITE) items[n].events |= POLLOUT;
        items[n].revents = 0;
        owners[n] = token;
        ++n;
    }
    if (poll(items, n, timeout) < 0) return errno == EINTR ? 0 : GW_TCP_FAILED;
    for (nfds_t i = 0; i < n; ++i) {
        short bits = items[i].revents;
        int32_t state = (bits & (POLLIN | POLLOUT | POLLHUP)) ? 1 : (bits & (POLLERR | POLLNVAL)) ? GW_TCP_FAILED : 0;
        if (state == 0) continue;
        tokens.data[count] = owners[i];
        ready.data[count] = state;
        ++count;
    }
#endif
    return count;
}

static int gw_tcp_nonblock(int fd) {
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0 || fcntl(fd, F_SETFD, FD_CLOEXEC) < 0) return 0;
#ifdef SO_NOSIGPIPE
    int one = 1;
    if (setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one)) < 0) return 0;
#endif
    return 1;
}

/* Starts a nonblocking connect to a numeric IPv4 or IPv6 address. Returns the descriptor, which may
   still be connecting: wait for writability, then ask gw_tcp_connect_result. Returns -1 for a bad
   address or port, or an immediate failure. Names are never resolved here. */
int32_t gw_tcp_connect_begin(gw_tcp_bytes host, int32_t port) {
    char text[GW_TCP_HOST_MAX_BYTES];
    if (port < 1 || port > 65535 || host.len <= 0 || host.len >= (int64_t)sizeof(text)) return GW_TCP_FAILED;
    memcpy(text, host.data, (size_t)host.len);
    text[host.len] = '\0';
    struct sockaddr_storage address;
    memset(&address, 0, sizeof(address));
    struct sockaddr_in *v4 = (struct sockaddr_in *)&address;
    struct sockaddr_in6 *v6 = (struct sockaddr_in6 *)&address;
    int family;
    socklen_t length;
    if (inet_pton(AF_INET, text, &v4->sin_addr) == 1) {
        family = AF_INET;
        v4->sin_family = AF_INET;
        v4->sin_port = htons((uint16_t)port);
        length = sizeof(*v4);
    } else if (inet_pton(AF_INET6, text, &v6->sin6_addr) == 1) {
        family = AF_INET6;
        v6->sin6_family = AF_INET6;
        v6->sin6_port = htons((uint16_t)port);
        length = sizeof(*v6);
    } else {
        return GW_TCP_FAILED;
    }
    int fd = socket(family, SOCK_STREAM, 0);
    if (fd < 0) return GW_TCP_FAILED;
    if (!gw_tcp_nonblock(fd)) { close(fd); return GW_TCP_FAILED; }
    if (connect(fd, (struct sockaddr *)&address, length) < 0 && errno != EINPROGRESS && errno != EINTR) {
        close(fd);
        return GW_TCP_FAILED;
    }
    return fd;
}

/* Sends FIN after the queued output (SHUT_WR). Input is still readable, so a lingering connection can
   discard what the peer sends until the peer closes; closing with unread input would send a reset. */
int32_t gw_tcp_half_close(int32_t fd) {
    return shutdown(fd, SHUT_WR) == 0 ? 0 : GW_TCP_FAILED;
}

/* After writability: 0 when the connection is established, else the socket error number (or -1). */
int32_t gw_tcp_connect_result(int32_t fd) {
    int error = 0;
    socklen_t length = sizeof(error);
    if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) < 0) return GW_TCP_FAILED;
    return error == 0 ? 0 : (int32_t)error;
}
