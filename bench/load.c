/* Keep-alive HTTP/1.1 load generator for Goose Web benchmarks.

   Build:  cc -O2 -Wall -Wextra bench/load.c -o build/load
   Usage:  build/load [-c connections] [-d seconds] [-p path] [-h host] [-P port]
   Defaults: 64 connections, 5 seconds, GET /health against 127.0.0.1:8080.

   Each connection keeps one request in flight and reuses its socket (HTTP/1.1 keep-alive). A response
   is framed by its Content-Length header; chunked responses are not supported. A connection the server
   closes (Connection: close, a timeout or an error) is counted as an error and reconnected. The output
   is one line: requests, errors, requests per second, and latency p50/p99/max in milliseconds. */
#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/socket.h>
#include <ctype.h>
#include <time.h>
#include <unistd.h>

#define RECV_BYTES (256 * 1024)
#define REQUEST_TIMEOUT_SECONDS 5.0

enum conn_state { CONN_CLOSED, CONN_CONNECTING, CONN_SENDING, CONN_RECEIVING };

typedef struct {
    int fd;
    enum conn_state state;
    size_t sent;
    size_t used;
    double started;
    char *buf;
} conn;

static const char *host = "127.0.0.1";
static int port = 8080;
static const char *path = "/health";
static char request[1024];
static size_t request_len;
static uint32_t *latencies_us;
static size_t latency_count, latency_capacity;
static long long errors;

static double now_seconds(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (double)t.tv_sec + (double)t.tv_nsec / 1e9;
}

static void record_latency(double seconds) {
    if (latency_count == latency_capacity) {
        size_t next = latency_capacity ? latency_capacity * 2 : 65536;
        uint32_t *grown = realloc(latencies_us, next * sizeof(uint32_t));
        if (grown == NULL) { perror("realloc"); exit(1); }
        latencies_us = grown;
        latency_capacity = next;
    }
    double micros = seconds * 1e6;
    latencies_us[latency_count++] = micros > 4e9 ? 4000000000u : (uint32_t)micros;
}

static int compare_u32(const void *a, const void *b) {
    uint32_t x = *(const uint32_t *)a, y = *(const uint32_t *)b;
    return (x > y) - (x < y);
}

static void close_conn(conn *c) {
    if (c->fd >= 0) close(c->fd);
    c->fd = -1;
    c->state = CONN_CLOSED;
    c->sent = 0;
    c->used = 0;
}

static void fail_conn(conn *c) {
    errors++;
    close_conn(c);
}

static void start_connect(conn *c) {
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons((uint16_t)port);
    inet_pton(AF_INET, host, &addr.sin_addr);
    c->fd = socket(AF_INET, SOCK_STREAM, 0);
    if (c->fd < 0) { perror("socket"); exit(1); }
    int flags = fcntl(c->fd, F_GETFL, 0);
    fcntl(c->fd, F_SETFL, flags | O_NONBLOCK);
    int one = 1;
    setsockopt(c->fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
    c->used = 0;
    if (connect(c->fd, (struct sockaddr *)&addr, sizeof(addr)) == 0) {
        c->state = CONN_SENDING;
    } else if (errno == EINPROGRESS) {
        c->state = CONN_CONNECTING;
    } else {
        fail_conn(c);
        return;
    }
    c->sent = 0;
    c->started = now_seconds();
}

/* Sends the rest of the request; stops at would-block and resumes on the next POLLOUT. */
static void send_request(conn *c) {
    while (c->sent < request_len) {
        ssize_t n = send(c->fd, request + c->sent, request_len - c->sent, MSG_NOSIGNAL);
        if (n < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) return;
            fail_conn(c);
            return;
        }
        c->sent += (size_t)n;
    }
    c->state = CONN_RECEIVING;
    c->used = 0;
}

/* Parses the Content-Length of the header block [0, head_end). Returns -1 when it is absent or bad. */
static long long content_length(const char *head, size_t head_len) {
    size_t i = 0;
    while (i < head_len) {
        size_t line_end = i;
        while (line_end + 1 < head_len && !(head[line_end] == '\r' && head[line_end + 1] == '\n')) line_end++;
        if (line_end - i > 15 && strncasecmp(head + i, "Content-Length:", 15) == 0) {
            long long value = 0;
            for (size_t k = i + 15; k < line_end; ++k) {
                if (head[k] == ' ' || head[k] == '\t') continue;
                if (head[k] < '0' || head[k] > '9') return -1;
                value = value * 10 + (head[k] - '0');
            }
            return value;
        }
        i = line_end + 2;
    }
    return 0;
}

/* Case-insensitive search for needle in text[0, length). */
static int contains_ci(const char *text, size_t length, const char *needle) {
    size_t n = strlen(needle);
    for (size_t i = 0; i + n <= length; ++i) {
        size_t k = 0;
        while (k < n && tolower((unsigned char)text[i + k]) == tolower((unsigned char)needle[k])) k++;
        if (k == n) return 1;
    }
    return 0;
}

/* True when the header block carries a Connection header with the close token. */
static int server_closes(const char *head, size_t head_len) {
    size_t i = 0;
    while (i < head_len) {
        size_t line_end = i;
        while (line_end + 1 < head_len && !(head[line_end] == '\r' && head[line_end + 1] == '\n')) line_end++;
        if (line_end - i > 11 && strncasecmp(head + i, "Connection:", 11) == 0 &&
            contains_ci(head + i + 11, line_end - i - 11, "close")) return 1;
        i = line_end + 2;
    }
    return 0;
}

/* Reads what the socket has. When a whole response is buffered, records its latency and starts the next
   request on the same connection while the run is still issuing; otherwise the connection is closed.
   Returns 1 when a response completed. */
static int receive(conn *c, double stop_issuing) {
    ssize_t n = recv(c->fd, c->buf + c->used, RECV_BYTES - c->used, 0);
    if (n == 0) { fail_conn(c); return 0; }
    if (n < 0) {
        if (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) fail_conn(c);
        return 0;
    }
    c->used += (size_t)n;
    size_t head_len = 0;
    for (size_t i = 0; i + 3 < c->used; ++i) {
        if (c->buf[i] == '\r' && c->buf[i + 1] == '\n' && c->buf[i + 2] == '\r' && c->buf[i + 3] == '\n') {
            head_len = i + 4;
            break;
        }
    }
    if (head_len == 0) {
        if (c->used == RECV_BYTES) fail_conn(c);
        return 0;
    }
    long long body = content_length(c->buf, head_len);
    if (body < 0 || head_len + (size_t)body > RECV_BYTES) { fail_conn(c); return 0; }
    if (c->used < head_len + (size_t)body) return 0;
    if (c->used != head_len + (size_t)body) { fail_conn(c); return 0; }   /* a response we did not ask for */
    double now = now_seconds();
    record_latency(now - c->started);
    if (server_closes(c->buf, head_len) || now >= stop_issuing) {
        close_conn(c);
        return 1;
    }
    c->state = CONN_SENDING;   /* keep-alive: the next request goes out on the same socket */
    c->sent = 0;
    c->used = 0;
    c->started = now;
    return 1;
}

int main(int argc, char **argv) {
    int connections = 64;
    double seconds = 5.0;
    for (int i = 1; i < argc; i += 2) {
        if (i + 1 >= argc) { fprintf(stderr, "option %s needs a value\n", argv[i]); return 2; }
        if (strcmp(argv[i], "-c") == 0) connections = atoi(argv[i + 1]);
        else if (strcmp(argv[i], "-d") == 0) seconds = atof(argv[i + 1]);
        else if (strcmp(argv[i], "-p") == 0) path = argv[i + 1];
        else if (strcmp(argv[i], "-h") == 0) host = argv[i + 1];
        else if (strcmp(argv[i], "-P") == 0) port = atoi(argv[i + 1]);
        else { fprintf(stderr, "usage: %s [-c connections] [-d seconds] [-p path] [-h host] [-P port]\n", argv[0]); return 2; }
    }
    if (connections < 1 || connections > 4096 || seconds <= 0 || port < 1 || port > 65535) {
        fprintf(stderr, "invalid arguments\n");
        return 2;
    }
    request_len = (size_t)snprintf(request, sizeof(request),
                                   "GET %s HTTP/1.1\r\nHost: %s:%d\r\n\r\n", path, host, port);
    if (request_len >= sizeof(request)) { fprintf(stderr, "path too long\n"); return 2; }
    signal(SIGPIPE, SIG_IGN);

    conn *conns = calloc((size_t)connections, sizeof(conn));
    if (conns == NULL) { perror("calloc"); return 1; }
    for (int i = 0; i < connections; ++i) {
        conns[i].fd = -1;
        conns[i].buf = malloc(RECV_BYTES);
        if (conns[i].buf == NULL) { perror("malloc"); return 1; }
    }

    double start = now_seconds();
    double stop_issuing = start + seconds;
    double hard_stop = stop_issuing + REQUEST_TIMEOUT_SECONDS;
    long long completed = 0;
    for (int i = 0; i < connections; ++i) start_connect(&conns[i]);

    struct pollfd *fds = calloc((size_t)connections, sizeof(struct pollfd));
    if (fds == NULL) { perror("calloc"); return 1; }
    for (;;) {
        double now = now_seconds();
        int live = 0;
        for (int i = 0; i < connections; ++i) {
            conn *c = &conns[i];
            if (c->fd >= 0 && now - c->started > REQUEST_TIMEOUT_SECONDS) fail_conn(c);
            if (c->fd >= 0) live++;
            else if (now < stop_issuing) start_connect(c);
        }
        if (live == 0 || now >= hard_stop) break;
        if (now >= stop_issuing) {
            // Let requests already in flight finish, then stop.
            int in_flight = 0;
            for (int i = 0; i < connections; ++i) if (conns[i].fd >= 0 && conns[i].state != CONN_CLOSED) in_flight++;
            if (in_flight == 0) break;
        }
        int count = 0;
        for (int i = 0; i < connections; ++i) {
            if (conns[i].fd < 0) continue;
            fds[count].fd = conns[i].fd;
            fds[count].events = conns[i].state == CONN_CONNECTING || conns[i].state == CONN_SENDING ? POLLOUT : POLLIN;
            fds[count].revents = 0;
            count++;
        }
        if (count == 0) continue;
        if (poll(fds, (nfds_t)count, 10) < 0 && errno != EINTR) { perror("poll"); return 1; }
        for (int k = 0; k < count; ++k) {
            if (fds[k].revents == 0) continue;
            conn *c = NULL;
            for (int i = 0; i < connections; ++i) if (conns[i].fd == fds[k].fd) { c = &conns[i]; break; }
            if (c == NULL) continue;
            if (c->state == CONN_CONNECTING) {
                int error = 0;
                socklen_t length = sizeof(error);
                getsockopt(c->fd, SOL_SOCKET, SO_ERROR, &error, &length);
                if (error != 0) { fail_conn(c); continue; }
                c->state = CONN_SENDING;
            }
            if (c->state == CONN_SENDING) {
                if (fds[k].revents & (POLLERR | POLLHUP | POLLNVAL)) { fail_conn(c); continue; }
                send_request(c);
            } else if (c->state == CONN_RECEIVING) {
                if (fds[k].revents & (POLLIN | POLLHUP | POLLERR)) completed += receive(c, stop_issuing);
            }
        }
    }
    double elapsed = now_seconds() - start;
    for (int i = 0; i < connections; ++i) close_conn(&conns[i]);

    qsort(latencies_us, latency_count, sizeof(uint32_t), compare_u32);
    double p50 = 0, p99 = 0, max = 0;
    if (latency_count > 0) {
        p50 = latencies_us[(latency_count - 1) * 50 / 100] / 1000.0;
        p99 = latencies_us[(latency_count - 1) * 99 / 100] / 1000.0;
        max = latencies_us[latency_count - 1] / 1000.0;
    }
    printf("%s  connections=%d seconds=%.1f requests=%lld errors=%lld rps=%.0f p50=%.3fms p99=%.3fms max=%.3fms\n",
           path, connections, elapsed, completed, errors,
           elapsed > 0 ? completed / elapsed : 0.0, p50, p99, max);
    free(fds);
    for (int i = 0; i < connections; ++i) free(conns[i].buf);
    free(conns);
    free(latencies_us);
    return 0;
}
