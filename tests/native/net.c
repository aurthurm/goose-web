#include "../../native/posix/net.c"
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>

/* Reactor tokens, interest changes, a nonblocking connect to a live listener, and a refused port. */
static void reactor_tests(void) {
    int32_t tokens[GW_TCP_MAX_TOKENS], states[GW_TCP_MAX_TOKENS];
    int pair[2];
    assert(socketpair(AF_UNIX, SOCK_STREAM, 0, pair) == 0);
    assert(gw_tcp_nonblock(pair[0]) && gw_tcp_nonblock(pair[1]));
    assert(gw_tcp_reactor_open(0) < 0 && gw_tcp_reactor_open(GW_TCP_MAX_TOKENS + 1) < 0);
    assert(gw_tcp_wait((gw_tcp_ints){tokens, GW_TCP_MAX_TOKENS}, (gw_tcp_ints){states, GW_TCP_MAX_TOKENS}, 0) < 0);
    assert(gw_tcp_reactor_open(8) == 0 && gw_tcp_reactor_open(8) < 0);
    assert(gw_tcp_add(2, pair[1], GW_TCP_INTEREST_READ) == 0);
    assert(gw_tcp_add(2, pair[1], GW_TCP_INTEREST_READ) < 0);     /* token in use */
    assert(gw_tcp_add(8, pair[1], GW_TCP_INTEREST_READ) < 0);     /* beyond capacity */
    assert(gw_tcp_add(3, pair[0], 4) < 0);                        /* unknown interest bit */
    assert(gw_tcp_set_interest(2, pair[0], GW_TCP_INTEREST_READ) < 0); /* wrong descriptor */
    assert(gw_tcp_wait((gw_tcp_ints){tokens, 8}, (gw_tcp_ints){states, 8}, 0) == 0);
    /* Write interest on an empty socket is ready; with no interest nothing is reported. */
    assert(gw_tcp_set_interest(2, pair[1], GW_TCP_INTEREST_WRITE) == 0);
    assert(gw_tcp_wait((gw_tcp_ints){tokens, 8}, (gw_tcp_ints){states, 8}, 1000) == 1 && tokens[0] == 2);
    assert(gw_tcp_set_interest(2, pair[1], 0) == 0);
    assert(write(pair[0], "x", 1) == 1);
    assert(gw_tcp_wait((gw_tcp_ints){tokens, 8}, (gw_tcp_ints){states, 8}, 0) == 0);  /* paused */
    assert(gw_tcp_set_interest(2, pair[1], GW_TCP_INTEREST_READ) == 0);
    assert(gw_tcp_wait((gw_tcp_ints){tokens, 8}, (gw_tcp_ints){states, 8}, 1000) == 1 && tokens[0] == 2);
    char input[8];
    assert(read(pair[1], input, sizeof(input)) == 1);
    gw_tcp_remove(2, pair[1]);
    gw_tcp_remove(2, pair[1]);                                    /* second removal is ignored */
    close(pair[1]);
    close(pair[0]);
    gw_tcp_reactor_close();
    gw_tcp_reactor_close();
}

/* A loopback listener: a nonblocking connect completes; a closed port is refused. */
static void connect_tests(void) {
    assert(gw_tcp_reactor_open(4) == 0);
    int server = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = 0;
    assert(bind(server, (struct sockaddr *)&addr, sizeof(addr)) == 0);
    assert(listen(server, 4) == 0);
    socklen_t length = sizeof(addr);
    assert(getsockname(server, (struct sockaddr *)&addr, &length) == 0);
    int port = ntohs(addr.sin_port);
    int32_t tokens[4], states[4];
    int32_t fd = gw_tcp_connect_begin((gw_tcp_bytes){(uint8_t *)"127.0.0.1", 9}, port);
    assert(fd >= 0);
    assert(gw_tcp_add(0, fd, GW_TCP_INTEREST_WRITE) == 0);
    assert(gw_tcp_wait((gw_tcp_ints){tokens, 4}, (gw_tcp_ints){states, 4}, 2000) == 1);
    assert(gw_tcp_connect_result(fd) == 0);
    gw_tcp_remove(0, fd);
    close(fd);
    close(server);
    /* The port is free again, so the connect is refused. */
    /* Loopback may refuse at once (begin fails) or after the first wait; either is a failed connect. */
    int32_t refused = gw_tcp_connect_begin((gw_tcp_bytes){(uint8_t *)"127.0.0.1", 9}, port);
    if (refused >= 0) {
        assert(gw_tcp_add(1, refused, GW_TCP_INTEREST_WRITE) == 0);
        assert(gw_tcp_wait((gw_tcp_ints){tokens, 4}, (gw_tcp_ints){states, 4}, 2000) == 1);
        assert(gw_tcp_connect_result(refused) > 0);
        gw_tcp_remove(1, refused);
        close(refused);
    }
    /* Half-close sends FIN: the peer reads end of input while our side can still read. */
    int pair2[2];
    assert(socketpair(AF_UNIX, SOCK_STREAM, 0, pair2) == 0);
    assert(gw_tcp_half_close(pair2[0]) == 0);
    char byte;
    assert(read(pair2[1], &byte, 1) == 0);
    assert(write(pair2[1], "y", 1) == 1);
    assert(read(pair2[0], &byte, 1) == 1 && byte == 'y');
    close(pair2[0]);
    close(pair2[1]);
    /* Names and bad ports never start a connect. */
    assert(gw_tcp_connect_begin((gw_tcp_bytes){(uint8_t *)"localhost", 9}, 80) < 0);
    assert(gw_tcp_connect_begin((gw_tcp_bytes){(uint8_t *)"127.0.0.1", 9}, 0) < 0);
    assert(gw_tcp_connect_begin((gw_tcp_bytes){(uint8_t *)"::1", 3}, 70000) < 0);
    gw_tcp_reactor_close();
}

int main(void) {
    reactor_tests();
    connect_tests();
    puts("TCP native tests passed: reactor tokens and interest, nonblocking connect, refused port, bad address");
    return 0;
}
