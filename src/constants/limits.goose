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
const MAX_PATH_PARAMS = 16;
const MAX_ALLOW_BYTES = MAX_HEADER_VALUE_BYTES;
const MAX_QUERY_FIELD_BYTES = 1024;
const MAX_EVENT_LISTENERS = 64;
const MAX_QUEUED_EVENTS = 256;
const INVALID_SUBSCRIPTION = 0;
// One Set-Cookie line written by the session middleware (name, value and attributes). Longer
// than a header value, so it has its own field in Response; 4096 is the RFC 6265 minimum that
// user agents must accept for a cookie.
const MAX_COOKIE_LINE_BYTES = 4096;
