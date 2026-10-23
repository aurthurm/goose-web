#ifndef GOOSE_WEB_POSIX_CONSTANTS_H
#define GOOSE_WEB_POSIX_CONSTANTS_H

/* Match src/constants/{limits,runtime}.goose. The unit suite compares the
   exported capacity query against Goose's MAX_CLIENTS across the ABI. */
#define GW_MAX_CLIENTS 64
#define GW_MAX_POLL_FDS (GW_MAX_CLIENTS + 1)
#define GW_SOCKET_BACKLOG GW_MAX_CLIENTS
#define GW_IO_WOULD_BLOCK (-2)
#define GW_INVALID_SOCKET (-1)
#define GW_IO_ERROR GW_INVALID_SOCKET
#define GW_POLL_READ 1
#define GW_POLL_WRITE 2
#define GW_MIN_PORT 1
#define GW_MAX_PORT 65535
#define GW_BIND_LOOPBACK 0
#define GW_BIND_PUBLIC 1
/* src/sys/files.goose and src/sys/process.goose mirror these values. */
#define GW_PATH_MAX_BYTES 4096
#define GW_ENV_NAME_MAX_BYTES 256
#define GW_FILE_MISSING 0
#define GW_FILE_REGULAR 1
#define GW_FILE_DIRECTORY 2
#define GW_FILE_OTHER 3
#define GW_FILE_ERROR (-1)
#define GW_ENV_UNSET (-1)
#define GW_ENV_TOO_LONG (-2)

#endif
