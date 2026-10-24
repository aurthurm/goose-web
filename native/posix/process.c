/* Process calls for the pre-forked worker model (src/runtime/server.goose, serve_workers).
   Each function borrows its arguments for the call only and retains no Goose pointers. */
#define _POSIX_C_SOURCE 200809L
#include <stdint.h>
#include <stddef.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>
#include <poll.h>
#ifdef __linux__
#include <sys/prctl.h>
#endif
#include "constants.h"

typedef struct { uint8_t *data; int64_t len; } gw_bytes;

/* Forks. In the child on Linux, the kernel sends SIGTERM when the parent dies, so an
   orphaned worker shuts down through its normal drain instead of serving on its own. */
int32_t gw_fork(void) {
    pid_t pid = fork();
    if (pid < 0) return GW_IO_ERROR;
#ifdef __linux__
    if (pid == 0) prctl(PR_SET_PDEATHSIG, SIGTERM);
#endif
    return (int32_t)pid;
}

int32_t gw_getpid(void) { return (int32_t)getpid(); }

/* Online processor count for workers = 0 (one per CPU). Never less than 1. */
int32_t gw_cpu_count(void) {
    long n = sysconf(_SC_NPROCESSORS_ONLN);
    if (n < 1) return 1;
    if (n > GW_MAX_WORKERS) return GW_MAX_WORKERS;
    return (int32_t)n;
}

int32_t gw_kill(int32_t pid, int32_t signal_number) {
    return kill((pid_t)pid, signal_number) == 0 ? 0 : GW_IO_ERROR;
}

/* Nonblocking reap. Returns GW_CHILD_RUNNING while the child lives. Otherwise returns
   GW_CHILD_REAPED and stores the status: the exit code (0..255) or 256 + the signal number.
   A wait error (for example the child was already reaped) also counts as reaped, with status -1. */
int32_t gw_wait_child(int32_t pid, int32_t *status) {
    int raw = 0;
    pid_t r = waitpid((pid_t)pid, &raw, WNOHANG);
    if (r == 0) return GW_CHILD_RUNNING;
    if (r < 0) { *status = -1; return GW_CHILD_REAPED; }
    if (WIFEXITED(raw)) *status = WEXITSTATUS(raw);
    else if (WIFSIGNALED(raw)) *status = 256 + WTERMSIG(raw);
    else *status = -1;
    return GW_CHILD_REAPED;
}

/* A one-way channel for fixed-size records. The read end is nonblocking; the write end is not,
   which is fine: a record is a few words, written at worker exit, far below PIPE_BUF. */
/* Waits until fd is readable or timeout_ms passes: 1 readable (or hung up), 0 timeout or
   interrupted, -1 error. The supervisor waits on one pipe, so it keeps no reactor state that
   forked workers would inherit. */
int32_t gw_wait_readable(int32_t fd, int32_t timeout_ms) {
    struct pollfd item = { .fd = fd, .events = POLLIN, .revents = 0 };
    int rc = poll(&item, 1, timeout_ms);
    if (rc < 0) return errno == EINTR ? 0 : -1;
    return rc > 0 ? 1 : 0;
}

int32_t gw_pipe(int32_t *read_end, int32_t *write_end) {
    int fds[2];
    if (pipe(fds) != 0) return GW_IO_ERROR;
    int flags = fcntl(fds[0], F_GETFL, 0);
    if (flags < 0 || fcntl(fds[0], F_SETFL, flags | O_NONBLOCK) < 0 ||
        fcntl(fds[0], F_SETFD, FD_CLOEXEC) < 0 || fcntl(fds[1], F_SETFD, FD_CLOEXEC) < 0) {
        close(fds[0]);
        close(fds[1]);
        return GW_IO_ERROR;
    }
    *read_end = fds[0];
    *write_end = fds[1];
    return 0;
}

/* Writes the whole frame or fails. The frame is opaque bytes; server.goose owns its layout.
   Returns the frame length, or GW_IO_ERROR. */
int64_t gw_pipe_write_record(int32_t fd, gw_bytes frame) {
    const uint8_t *at = frame.data;
    int64_t size = frame.len;
    int64_t done = 0;
    while (done < size) {
        ssize_t n = write(fd, at + done, (size_t)(size - done));
        if (n < 0) {
            if (errno == EINTR) continue;
            return GW_IO_ERROR;
        }
        done += (int64_t)n;
    }
    return done;
}

/* Reads one whole frame into frame. Returns the frame length, GW_IO_WOULD_BLOCK when nothing is
   available yet, 0 at end of file, or GW_IO_ERROR. A partial frame is never returned as
   complete: the caller reads with the frame length, and the writes are atomic. */
int64_t gw_pipe_read_record(int32_t fd, gw_bytes frame) {
    uint8_t *at = frame.data;
    int64_t size = frame.len;
    int64_t done = 0;
    while (done < size) {
        ssize_t n = read(fd, at + done, (size_t)(size - done));
        if (n == 0) return done == 0 ? 0 : GW_IO_ERROR;
        if (n < 0) {
            if (errno == EINTR) continue;
            if ((errno == EAGAIN || errno == EWOULDBLOCK) && done == 0) return GW_IO_WOULD_BLOCK;
            return GW_IO_ERROR;
        }
        done += (int64_t)n;
    }
    return done;
}
