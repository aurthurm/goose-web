import .limits;
namespace web;

// Release version; must match the VERSION file at the repository root (checked by tests/run.py).
const VERSION = "0.6.0";
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
// The reactor registers the listener under LISTENER_TOKEN and each connection under its slot.
const MAX_POLL_FDS = MAX_CLIENTS + 1;
const LISTENER_TOKEN = MAX_CLIENTS;
const IO_WOULD_BLOCK = -2;
const INVALID_SOCKET = -1;
// Connection input blocks start at INPUT_MIN_BYTES and double up to max_request_bytes, so
// INPUT_CLASSES sizes cover MAX_REQUEST_BYTES. See InputPool in server.goose.
const INPUT_MIN_BYTES = 1024;
const INPUT_CLASSES = 4;

const SERVER_STARTED = 1;
const SERVER_STOPPING = 2;
const SERVER_STOPPED = 3;

// Worker processes (workers != 1). 1 keeps the single-process reactor; 0 means one per CPU.
const DEFAULT_WORKERS = 1;
// One ServerStats record on the worker pipe: twelve i64 fields, written whole (writes below PIPE_BUF are atomic).
const STATS_RECORD_BYTES = 96;
// A worker that exits without being asked is restarted after a backoff that doubles from the
// minimum to the maximum. A worker that lived this long resets its backoff.
const WORKER_BACKOFF_MIN_MS = 50;
const WORKER_BACKOFF_MAX_MS = 2000;
const WORKER_STABLE_MS = 10000;
// More restarts than this within WORKER_RESTART_WINDOW_MS stop the whole server with an error.
const WORKER_RESTART_BUDGET = 30;
const WORKER_RESTART_WINDOW_MS = 60000;
// Children have the full shutdown grace period; the parent then sends SIGKILL this much later.
const WORKER_KILL_MARGIN_MS = 500;
// How long the parent sleeps between supervision passes when no stats record arrives.
const WORKER_SUPERVISE_MS = 20;
const SIGNAL_TERM = 15;
const SIGNAL_KILL = 9;
