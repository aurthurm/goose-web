import .limits;
namespace web;

const DEFAULT_PORT = 8080;
const MIN_PORT = 1;
const MAX_PORT = 65535;
const DEFAULT_PUBLIC_BIND = false;
const DEFAULT_MAX_CLIENTS = MAX_CLIENTS;
const DEFAULT_MAX_REQUEST_BYTES = MAX_REQUEST_BYTES;
const DEFAULT_READ_TIMEOUT_MS = 5000;
const DEFAULT_WRITE_TIMEOUT_MS = 5000;
const DEFAULT_POLL_TIMEOUT_MS = 10;
const DEFAULT_SHUTDOWN_GRACE_MS = 5000;
const DEFAULT_IDLE_TIMEOUT_MS = 5000;
const DEFAULT_KEEP_ALIVE = true;
const DEFAULT_MAX_REQUESTS_PER_CONNECTION = 100;
const MAX_REQUESTS_PER_CONNECTION = 1000000;
const DEFAULT_MAX_RESPONSE_BYTES = 1048576;
// Serialized responses are copied into chunks from one pool, linked in order. A connection
// slot stores only its head chunk, so idle slots cost no response storage. The pool holds
// at most max_pool_bytes (default 8 MiB); a response that does not fit gets a 503.
const RESPONSE_CHUNK_BYTES = 16384;
const DEFAULT_MAX_POOL_BYTES = 8388608;
// Streams are limited to min(max_sse_clients, max_clients); see docs/design/app-api.md.
const DEFAULT_MAX_SSE_CLIENTS = 32;
const MAX_SSE_CLIENTS = MAX_CLIENTS;
const DEFAULT_SSE_HEARTBEAT_MS = 15000;
const DEFAULT_SSE_MAX_QUEUED_BYTES = 262144;
const MAX_POOL_CHUNKS = MAX_RESPONSE_POOL_BYTES / RESPONSE_CHUNK_BYTES;
const NO_CHUNK = -1;
const DEFAULT_HANDLE_SIGNALS = false;
const UNLIMITED_REQUESTS = 0;
const MAX_TIMEOUT_MS = 86400000;
const MAX_POLL_TIMEOUT_MS = 1000;
const NANOSECONDS_PER_MILLISECOND = 1000000;
const ACCEPT_BUDGET = 16;
const MAX_POLL_FDS = MAX_CLIENTS + 1;
const IO_WOULD_BLOCK = -2;
const INVALID_SOCKET = -1;
const POLL_READ = 1;
const POLL_WRITE = 2;

const SERVER_STARTED = 1;
const SERVER_STOPPING = 2;
const SERVER_STOPPED = 3;
