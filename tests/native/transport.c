#include "../../native/posix/transport.c"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static volatile sig_atomic_t restored_signal;
static void previous_handler(int number) { restored_signal = number; }

/* Reactor: registration, interest changes, removal and wait. Built once with epoll and once with
   -DGW_REACTOR_POLL, so both backends run the same checks. */
static void reactor_tests(void) {
    int pair[2];
    assert(socketpair(AF_UNIX, SOCK_STREAM, 0, pair) == 0);
    assert(gw_nonblock(pair[0]) >= 0 && gw_nonblock(pair[1]) >= 0);
    int32_t tokens[GW_MAX_POLL_FDS], states[GW_MAX_POLL_FDS];
    gw_ints token_slice = {tokens, GW_MAX_POLL_FDS}, state_slice = {states, GW_MAX_POLL_FDS};
    assert(gw_reactor_wait(token_slice, state_slice, 0) < 0);   /* not open */
    assert(gw_reactor_open() == 0 && gw_reactor_open() < 0);     /* one reactor per process */
    assert(gw_reactor_add(3, pair[1], 0) == 0);
    assert(gw_reactor_add(3, pair[1], 0) < 0);                  /* token in use */
    assert(gw_reactor_add(GW_MAX_POLL_FDS, pair[1], 0) < 0);
    assert(gw_reactor_add(-1, pair[1], 0) < 0);
    assert(gw_reactor_modify(4, pair[1], 0) < 0);               /* unknown token */
    assert(gw_reactor_modify(3, pair[0], 0) < 0);               /* wrong descriptor */
    assert(gw_reactor_wait(token_slice, state_slice, 0) == 0);  /* nothing readable yet */
    /* Write interest on an empty socket reports writable, and only once. */
    assert(gw_reactor_modify(3, pair[1], 1) == 0);
    assert(gw_reactor_modify(3, pair[1], 1) == 0);              /* same interest: no change */
    assert(gw_reactor_wait(token_slice, state_slice, 1000) == 1 && tokens[0] == 3 && states[0] == 1);
    assert(gw_reactor_modify(3, pair[1], 0) == 0);
    assert(gw_reactor_wait(token_slice, state_slice, 0) == 0);  /* read interest, no data */
    /* Data arrives: the read interest reports it, and draining it clears the event. */
    assert(write(pair[0], "x", 1) == 1);
    assert(gw_reactor_wait(token_slice, state_slice, 1000) == 1 && tokens[0] == 3 && states[0] == 1);
    uint8_t input[16];
    assert(gw_recv(pair[1], (gw_bytes){input, sizeof(input)}) == 1);
    assert(gw_reactor_wait(token_slice, state_slice, 0) == 0);
    /* A removed registration reports nothing, even with data waiting. */
    gw_reactor_remove(3, pair[1]);
    gw_reactor_remove(3, pair[1]);                              /* second removal is ignored */
    assert(write(pair[0], "y", 1) == 1);
    assert(gw_reactor_wait(token_slice, state_slice, 0) == 0);
    assert(gw_reactor_add(3, pair[1], 0) == 0);                 /* the token can be reused */
    assert(gw_reactor_wait(token_slice, state_slice, 1000) == 1 && tokens[0] == 3);
    assert(gw_recv(pair[1], (gw_bytes){input, sizeof(input)}) == 1);
    /* A negative length is refused before the socket call, so no byte moves and the data stays queued. */
    assert(write(pair[0], "z", 1) == 1);
    assert(gw_reactor_wait(token_slice, state_slice, 1000) == 1 && tokens[0] == 3 && states[0] == 1);
    assert(gw_recv(pair[1], (gw_bytes){input, -1}) == GW_IO_ERROR);
    assert(gw_send(pair[1], (gw_bytes){input, -1}) == GW_IO_ERROR);
    assert(gw_recv(pair[1], (gw_bytes){NULL, 4}) == GW_IO_ERROR);
    assert(gw_recv(pair[1], (gw_bytes){input, sizeof(input)}) == 1 && input[0] == 'z');
    /* The peer closing is readable, so the reactor reports EOF to the connection. */
    gw_close(pair[0]);
    assert(gw_reactor_wait(token_slice, state_slice, 1000) == 1 && tokens[0] == 3 && states[0] == 1);
    assert(gw_recv(pair[1], (gw_bytes){input, sizeof(input)}) == 0);
    gw_reactor_remove(3, pair[1]);
    gw_close(pair[1]);
    gw_reactor_close();
    gw_reactor_close();
    assert(gw_reactor_open() == 0);                             /* reopens after a close */
    gw_reactor_close();
}

int main(void) {
    reactor_tests();
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
