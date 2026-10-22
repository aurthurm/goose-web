#include "../../native/posix/transport.c"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static volatile sig_atomic_t restored_signal;
static void previous_handler(int number) { restored_signal = number; }

int main(void) {
    assert(gw_transport_max_clients() == GW_MAX_CLIENTS);
    assert(GW_MAX_POLL_FDS == GW_MAX_CLIENTS + 1);
    assert(GW_SOCKET_BACKLOG == GW_MAX_CLIENTS);
    struct sigaction action = {0}, original;
    action.sa_handler = previous_handler;
    sigemptyset(&action.sa_mask);
    assert(sigaction(SIGINT, &action, &original) == 0);
    assert(gw_signals_begin() == 0);
    assert(gw_signals_begin() == -1);
    assert(gw_signal_pending() == 0);
    assert(raise(SIGINT) == 0 && gw_signal_pending() == SIGINT);
    gw_signals_end();
    assert(raise(SIGINT) == 0 && restored_signal == SIGINT);
    assert(sigaction(SIGINT, &original, NULL) == 0);
    assert(gw_signals_begin() == 0 && gw_signal_pending() == 0);
    gw_signals_end();
    assert(gw_listen_config(8080, 2) == GW_INVALID_SOCKET);
    int pair[2];
    assert(socketpair(AF_UNIX, SOCK_STREAM, 0, pair) == 0);
    assert(gw_nonblock(pair[0]) >= 0 && gw_nonblock(pair[1]) >= 0);
    uint8_t input[16];
    assert(gw_recv(pair[1], (gw_bytes){input, sizeof(input)}) == GW_IO_WOULD_BLOCK);
    int size = 1024;
    assert(setsockopt(pair[0], SOL_SOCKET, SO_SNDBUF, &size, sizeof(size)) == 0);
    static uint8_t large[1024 * 1024];
    memset(large, 'x', sizeof(large));
    int64_t n = gw_send(pair[0], (gw_bytes){large, sizeof(large)});
    assert(n > 0 && n < (int64_t)sizeof(large));
    do { n = gw_send(pair[0], (gw_bytes){large, sizeof(large)}); } while (n > 0);
    assert(n == GW_IO_WOULD_BLOCK);
    assert(gw_recv(pair[1], (gw_bytes){input, sizeof(input)}) > 0);
    gw_close(pair[1]);
    assert(gw_send(pair[0], (gw_bytes){large, 1}) == GW_IO_ERROR);
    gw_close(pair[0]);
    assert(gw_listen(0) == GW_INVALID_SOCKET && gw_listen(65536) == GW_INVALID_SOCKET);
    puts("Transport tests passed: would-block, partial write, peer close, invalid port, signal ownership/restoration");
    return 0;
}
