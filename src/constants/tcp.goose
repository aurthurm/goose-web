namespace web;

// Custom-protocol TCP layer (src/net/tcp.goose). Capacities are fixed; TcpConfig picks working limits.
// native/posix/net.c mirrors TCP_TOKENS through its token capacity.
const TCP_MAX_CONNS = 1024;
// Token 0 is the listener; connection slot i uses token i + 1.
const TCP_TOKENS = TCP_MAX_CONNS + 1;
const TCP_LISTENER_TOKEN = 0;
// A connection id is generation * TCP_SLOT_SPAN + slot, so a stale id never names a reused slot.
const TCP_SLOT_SPAN = TCP_MAX_CONNS;
const TCP_NO_CONN = 0;
// Output is queued in chunks from one shared pool, as the HTTP server queues responses.
const TCP_CHUNK_BYTES = 4096;
const TCP_NO_CHUNK = -1;
// Framing buffers hold one line or one frame. Apps declare them (TcpFrame) with this capacity.
const TCP_FRAME_CAPACITY = 8192;
const TCP_PEER_BYTES = 64;
const TCP_ACCEPT_BUDGET = 16;
const TCP_NO_DEADLINE = -1;

const TCP_DEFAULT_PORT = 9000;
const TCP_DEFAULT_PUBLIC_BIND = false;
const TCP_DEFAULT_MAX_CONNS = 256;
const TCP_DEFAULT_READ_BUFFER_BYTES = 16384;
const TCP_MAX_READ_BUFFER_BYTES = 1048576;
const TCP_DEFAULT_MAX_WRITE_QUEUE_BYTES = 262144;
const TCP_MAX_WRITE_QUEUE_BYTES = 16777216;
// 0 disables the idle timeout. Activity is a read, or a write that makes progress.
const TCP_DEFAULT_IDLE_TIMEOUT_MS = 60000;
const TCP_DEFAULT_CONNECT_TIMEOUT_MS = 5000;
const TCP_DEFAULT_SHUTDOWN_GRACE_MS = 5000;
const TCP_DEFAULT_POLL_TIMEOUT_MS = 10;
const TCP_MAX_POLL_TIMEOUT_MS = 1000;
const TCP_MAX_TIMEOUT_MS = 86400000;
const TCP_DEFAULT_HANDLE_SIGNALS = false;

// Slot states.
const TCP_SLOT_FREE = 0;
const TCP_SLOT_CONNECTING = 1;
const TCP_SLOT_OPEN = 2;
// Closing: no more reads; queued output is flushed, then the slot half-closes (or at its deadline).
const TCP_SLOT_CLOSING = 3;
// Lingering: FIN has been sent. Input is read and discarded until the peer closes or the grace ends.
const TCP_SLOT_LINGER = 4;

// Interest bits given to the readiness instance.
const TCP_INTEREST_READ = 1;
const TCP_INTEREST_WRITE = 2;

// Close reasons, passed in the Closed event.
const TCP_CLOSE_PEER = 0;
const TCP_CLOSE_ERROR = 1;
const TCP_CLOSE_IDLE = 2;
const TCP_CLOSE_APP = 3;
const TCP_CLOSE_SHUTDOWN = 4;
const TCP_CLOSE_CONNECT_FAILED = 5;
const TCP_CLOSE_CONNECT_TIMEOUT = 6;
