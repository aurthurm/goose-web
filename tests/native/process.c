#include "../../native/posix/process.c"
#include <assert.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

/* Waits for pid to be reaped, polling nonblockingly. Returns the reap state, with the status stored. */
static int32_t reap(int32_t pid, int32_t *status) {
    struct timespec tick = {0, 1000000};
    for (int i = 0; i < 5000; ++i) {
        int32_t state = gw_wait_child(pid, status);
        if (state != GW_CHILD_RUNNING) return state;
        nanosleep(&tick, NULL);
    }
    return GW_CHILD_RUNNING;
}

int main(void) {
    assert(gw_getpid() == (int32_t)getpid());
    int32_t cpus = gw_cpu_count();
    assert(cpus >= 1 && cpus <= GW_MAX_WORKERS);

    /* A child's exit code comes back through the nonblocking reap. */
    int32_t child = gw_fork();
    assert(child >= 0);
    if (child == 0) _exit(7);
    int32_t status = -99;
    assert(reap(child, &status) == GW_CHILD_REAPED && status == 7);

    /* A child killed by a signal is reported as 256 + the signal number. */
    child = gw_fork();
    assert(child >= 0);
    if (child == 0) {
        for (;;) pause();
    }
    assert(gw_kill(child, SIGKILL) == 0);
    assert(reap(child, &status) == GW_CHILD_REAPED && status == 256 + SIGKILL);

    /* A pid that is not our child is reaped at once with status -1 (ECHILD). */
    assert(gw_wait_child(999999, &status) == GW_CHILD_REAPED && status == -1);
    /* pid 0 and negative pids name a process group or every child: both are refused, so no signal
       reaches this group and no unrelated child is reaped. */
    assert(gw_kill(0, SIGTERM) == GW_IO_ERROR && gw_kill(-1, SIGTERM) == GW_IO_ERROR);
    assert(gw_wait_child(0, &status) == GW_CHILD_REAPED && status == -1);
    assert(gw_wait_child(-1, &status) == GW_CHILD_REAPED && status == -1);

    /* Frames cross the pipe whole. An empty pipe reads WOULD_BLOCK; after the writer closes, EOF. */
    int32_t read_end = -1, write_end = -1;
    assert(gw_pipe(&read_end, &write_end) == 0);
    uint8_t out[96], in[96];
    for (int i = 0; i < 96; ++i) out[i] = (uint8_t)(i * 7);
    gw_bytes out_frame = {out, sizeof(out)};
    gw_bytes in_frame = {in, sizeof(in)};
    assert(gw_wait_readable(read_end, 0) == 0);      /* empty pipe: timeout */
    assert(gw_pipe_write_record(write_end, out_frame) == (int64_t)sizeof(out));
    assert(gw_wait_readable(read_end, 1000) == 1);   /* a frame is waiting */
    assert(gw_pipe_read_record(read_end, in_frame) == (int64_t)sizeof(in));
    assert(memcmp(out, in, sizeof(out)) == 0);
    assert(gw_pipe_read_record(read_end, in_frame) == GW_IO_WOULD_BLOCK);
    close(write_end);
    assert(gw_pipe_read_record(read_end, in_frame) == 0);
    close(read_end);

    puts("Process tests passed: fork and exit status, signals, nonblocking reap, record pipe, readable wait, CPU count");
    return 0;
}
