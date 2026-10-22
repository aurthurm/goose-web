/* Async-first proof of concept: nonblocking poll reactor, fixed slots.
 * Deliberately supports only a small header-only GET experiment and
 * closes every connection. NOT a complete HTTP parser or public server.
 */
#define _POSIX_C_SOURCE 200809L
#if defined(_WIN32)
#error POSIX-only prototype
#endif
#include <stdint.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <poll.h>
#include <sys/socket.h>
#include <netinet/in.h>
#define CAP 64
#define INPUT_CAP 8192
#define OUTPUT_CAP 8192
typedef struct { uint8_t *data; int64_t len; } mut_slice;
typedef struct { const uint8_t *data; int64_t len; } const_slice;
typedef struct {
    int fd, state;
    int64_t received, sent, output_len;
    uint8_t in[INPUT_CAP], out[OUTPUT_CAP];
} slot;
static slot clients[CAP];
static int server = -1;
static int set_nonblocking(int fd) {
    int f=fcntl(fd,F_GETFL,0);
    return f<0 ? -1 : fcntl(fd,F_SETFL,f|O_NONBLOCK);
}
static void close_slot(int i) {
    if (clients[i].state) close(clients[i].fd);
    memset(&clients[i],0,sizeof clients[i]);
}
int32_t gw_reactor_start(int32_t port) {
    if (server >= 0 || port < 1 || port > 65535) return -1;
    int fd=socket(AF_INET, SOCK_STREAM, 0);
    if (fd<0) return -1;
    int enable=1; (void)setsockopt(fd,SOL_SOCKET,SO_REUSEADDR,&enable,sizeof enable);
    struct sockaddr_in a={0}; a.sin_family=AF_INET;
    a.sin_addr.s_addr=htonl(INADDR_LOOPBACK); a.sin_port=htons((uint16_t)port);
    if (set_nonblocking(fd)<0 || bind(fd,(void*)&a,sizeof a)<0 ||
        listen(fd,CAP)<0) { close(fd); return -1; }
    server=fd;
    return 0;
}
/* state: free=0, read=1, ready=2, claimed=3, write=4.
 * Returns slot token 1..CAP if a complete header is ready, else zero.
 */
int32_t gw_reactor_poll(int32_t timeout_ms) {
    if (server<0) return -1;
    for(int i=0;i<CAP;i++)if(clients[i].state==2)return i+1;
    struct pollfd fds[CAP+1]; int ids[CAP+1],count=1;
    fds[0]=(struct pollfd){.fd=server,.events=POLLIN};ids[0]=-1;
    for(int i=0;i<CAP;i++)if(clients[i].state==1 || clients[i].state==4){
        ids[count]=i;
        fds[count++]=(struct pollfd){.fd=clients[i].fd,
             .events=clients[i].state==1?POLLIN:POLLOUT};
    }
    int n;
    do { n=poll(fds,(nfds_t)count,timeout_ms<0?0:timeout_ms); }
    while(n<0&&errno==EINTR);
    if(n<=0)return 0;
    if(fds[0].revents&POLLIN)for(;;){
        int fd=accept(server,NULL,NULL);
        if(fd<0){if(errno==EINTR)continue;break;}
        int free_slot=-1;
        for(int i=0;i<CAP;i++)if(!clients[i].state){free_slot=i;break;}
        if(free_slot<0 || set_nonblocking(fd)<0){close(fd);continue;}
        clients[free_slot].fd=fd;clients[free_slot].state=1;
    }
    for(int j=1;j<count;j++){
        int i=ids[j];slot *s=&clients[i];
        if(fds[j].revents&(POLLERR|POLLHUP|POLLNVAL)){close_slot(i);continue;}
        if(s->state==1&&(fds[j].revents&POLLIN)){
            if(s->received>=INPUT_CAP){close_slot(i);continue;}
            ssize_t got=recv(s->fd,s->in+s->received,
                             (size_t)(INPUT_CAP-s->received),0);
            if(got==0){close_slot(i);continue;}
            if(got<0){
                if(errno!=EAGAIN && errno!=EWOULDBLOCK && errno!=EINTR)close_slot(i);
                continue;
            }
            s->received+=got;
            for(int64_t k=3;k<s->received;k++)
                if(s->in[k-3]=='\r'&&s->in[k-2]=='\n'&&
                   s->in[k-1]=='\r'&&s->in[k]=='\n'){s->state=2;break;}
        } else if(s->state==4&&(fds[j].revents&POLLOUT)){
            ssize_t wrote;
#ifdef MSG_NOSIGNAL
            wrote=send(s->fd,s->out+s->sent,(size_t)(s->output_len-s->sent),MSG_NOSIGNAL);
#else
            wrote=send(s->fd,s->out+s->sent,(size_t)(s->output_len-s->sent),0);
#endif
            if(wrote>0)s->sent+=wrote;
            else if(wrote==0 || (errno!=EAGAIN&&errno!=EWOULDBLOCK&&errno!=EINTR)){
                close_slot(i);continue;
            }
            if(s->sent>=s->output_len)close_slot(i);
        }
    }
    for(int i=0;i<CAP;i++)if(clients[i].state==2)return i+1;
    return 0;
}
int64_t gw_reactor_take(int32_t token,mut_slice dst) {
    int i=token-1;
    if(i<0||i>=CAP||clients[i].state!=2||dst.len<clients[i].received||
       !dst.data)return -1;
    memcpy(dst.data,clients[i].in,(size_t)clients[i].received);
    clients[i].state=3;
    return clients[i].received;
}
int32_t gw_reactor_reply(int32_t token,const_slice data) {
    int i=token-1;
    if(i<0||i>=CAP||clients[i].state!=3||data.len<=0||
       data.len>OUTPUT_CAP||!data.data)return -1;
    memcpy(clients[i].out,data.data,(size_t)data.len);
    clients[i].output_len=data.len;
    clients[i].sent=0;
    clients[i].state=4;
    return 0;
}
void gw_reactor_shutdown(void){
    for(int i=0;i<CAP;i++)if(clients[i].state)close_slot(i);
    if(server>=0){close(server);server=-1;}
}
