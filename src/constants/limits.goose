namespace web;

// Fixed storage capacities. Configure smaller working limits via ServerConfig.
const MAX_CLIENTS = 64;
const MAX_REQUEST_BYTES = 8192;
const MAX_REQUEST = MAX_REQUEST_BYTES; // Compatibility with the original public name.
// Hard ceiling for any response body. A Response grows on demand up to its max_body,
// which the runtime sets from ServerConfig.max_response_bytes (1 MiB by default).
const MAX_RESPONSE_BODY_BYTES = 16777216;
// Room for the JSON error envelope of a refused write. Error envelopes may use this
// much beyond max_body, so a too-large body can still be replaced by its 500.
const MAX_ERROR_BODY_BYTES = 65536;
// Status line plus headers: 16 headers of at most 324 bytes plus fixed lines stay under 8 KiB.
const MAX_RESPONSE_HEADER_BYTES = 8192;
const MAX_RESPONSE_WIRE_BYTES = MAX_RESPONSE_BODY_BYTES + MAX_RESPONSE_HEADER_BYTES;
// Ceiling for ServerConfig.max_pool_bytes: bytes held by serialized responses in flight.
const MAX_RESPONSE_POOL_BYTES = 67108864;
const MAX_RESPONSE_HEADERS = 16;
const MAX_HEADER_NAME_BYTES = 64;
const MAX_HEADER_VALUE_BYTES = 256;
const MAX_CONTENT_TYPE_BYTES = 128;
const MAX_ROUTES = 64;
const MAX_METHOD_BYTES = 16;
const MAX_ROUTE_PATTERN_BYTES = 512;
// Host scope pattern: "example.com" or "*.example.com" (lowercase or not; compared ASCII-insensitively).
const MAX_HOST_PATTERN_BYTES = 128;
// Numeric peer address text: IPv4 dotted quad or IPv6 (inet_ntop), with room to spare.
const MAX_PEER_BYTES = 64;
const MAX_PATH_PARAMS = 16;
const MAX_ALLOW_BYTES = MAX_HEADER_VALUE_BYTES;
const MAX_QUERY_FIELD_BYTES = 1024;
const MAX_EVENT_LISTENERS = 64;
const MAX_QUEUED_EVENTS = 256;
const INVALID_SUBSCRIPTION = 0;
// Server-sent events. A stream queues at most sse_max_queued_bytes of unsent data; the close
// event may use SSE_CLOSE_RESERVE_BYTES beyond that. Publishes stage in a bounded outbox.
const MAX_SSE_QUEUED_BYTES = 4194304;
const MIN_SSE_QUEUED_BYTES = 256;
const SSE_CLOSE_RESERVE_BYTES = 128;
const MAX_SSE_EVENT_BYTES = 128;
const MAX_SSE_MESSAGE_BYTES = 65536;
const MAX_SSE_OUTBOX_BYTES = 262144;
const MAX_SSE_OUTBOX_MESSAGES = 64;
// Pre-forked worker processes (ServerConfig.workers). Each worker holds its own connection slots.
const MAX_WORKERS = 256;
// Shared store (native/posix/shared.c): an entry's key and value are bounded by its slot, and the
// store as a whole by MAX_SHARED_STORE_BYTES. Streams registered in it are capped at SHARED_STREAMS.
const SHARED_KEY_MAX_BYTES = 128;
const SHARED_VALUE_MAX_BYTES = 1024;
const MAX_SHARED_STORE_BYTES = 268435456;
const SHARED_STREAMS = 2048;

// One Set-Cookie line written by the session middleware (name, value and attributes). Longer
// than a header value, so it has its own field in Response; 4096 is the RFC 6265 minimum that
// user agents must accept for a cookie.
const MAX_COOKIE_LINE_BYTES = 4096;
