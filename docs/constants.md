# Public constants

Import `goose_web` as usual. Constants are available through `web::` alongside the
framework functions; applications do not need to import internal source files.

```goose
response.status = web::HTTP_CREATED;
response.content_type = web::CONTENT_TYPE_JSON;
assert(web::set_header(response, web::HEADER_REQUEST_ID, "request-42"));
assert(web::add_route(routes, web::METHOD_POST, "/items", create_item_id));

var config = web::server_config();
config.port = web::DEFAULT_PORT;
config.max_clients = web::MAX_CLIENTS / 2;
```

## HTTP names

The complete definitions are in [HTTP constants](../src/constants/http.goose).

| Group | Public names |
| --- | --- |
| Success | `HTTP_OK`, `HTTP_CREATED`, `HTTP_ACCEPTED`, `HTTP_NO_CONTENT`, `HTTP_PARTIAL_CONTENT` |
| Redirects | `HTTP_MOVED_PERMANENTLY`, `HTTP_FOUND`, `HTTP_SEE_OTHER`, `HTTP_NOT_MODIFIED`, `HTTP_TEMPORARY_REDIRECT`, `HTTP_PERMANENT_REDIRECT` |
| Common request errors | `HTTP_BAD_REQUEST`, `HTTP_UNAUTHORIZED`, `HTTP_FORBIDDEN`, `HTTP_NOT_FOUND`, `HTTP_METHOD_NOT_ALLOWED`, `HTTP_REQUEST_TIMEOUT`, `HTTP_CONFLICT`, `HTTP_GONE` |
| Validation and limits | `HTTP_CONTENT_TOO_LARGE`, `HTTP_UNSUPPORTED_MEDIA_TYPE`, `HTTP_EXPECTATION_FAILED`, `HTTP_UNPROCESSABLE_CONTENT`, `HTTP_TOO_MANY_REQUESTS`, `HTTP_REQUEST_HEADER_FIELDS_TOO_LARGE` |
| Server errors | `HTTP_INTERNAL_SERVER_ERROR`, `HTTP_NOT_IMPLEMENTED`, `HTTP_BAD_GATEWAY`, `HTTP_SERVICE_UNAVAILABLE`, `HTTP_GATEWAY_TIMEOUT`, `HTTP_VERSION_NOT_SUPPORTED` |
| Methods | `METHOD_GET`, `METHOD_HEAD`, `METHOD_POST`, `METHOD_PUT`, `METHOD_PATCH`, `METHOD_DELETE`, `METHOD_OPTIONS`, `METHOD_CONNECT`, `METHOD_TRACE` |
| Content types | `CONTENT_TYPE_JSON`, `CONTENT_TYPE_TEXT`, `CONTENT_TYPE_HTML`, `CONTENT_TYPE_OCTET_STREAM`, `CONTENT_TYPE_EVENT_STREAM` |
| Headers | `HEADER_HOST`, `HEADER_CONTENT_LENGTH`, `HEADER_CONTENT_TYPE`, `HEADER_CONNECTION`, `HEADER_TRANSFER_ENCODING`, `HEADER_EXPECT`, `HEADER_TRAILER`, `HEADER_UPGRADE`, `HEADER_ALLOW`, `HEADER_LOCATION`, `HEADER_REQUEST_ID`, `HEADER_CACHE_CONTROL` |
| Protocol | `HTTP_VERSION`, `CONNECTION_CLOSE` |

Every declared status has a corresponding `reason()` phrase. Constants describe
codes; they do not automatically implement range requests, redirects, CONNECT, or
other protocol features. The supported behavior remains in the [HTTP profile](http-conformance.md).
Use `response.content_type` for the content type; `set_header` still rejects headers
whose framing is managed by the framework.

`PARSE_INCOMPLETE` means a request needs more input. `QUERY_MISSING` means the key
was absent. Both currently equal zero, but their names describe separate contracts.
Completed parsing and successful routing/query lookup use `HTTP_OK`.

## Fixed limits

[Limit constants](../src/constants/limits.goose) define compiled storage capacities:

| Constant | Capacity |
| --- | --- |
| `MAX_CLIENTS` | 64 connections |
| `MAX_REQUEST_BYTES` | 8192 bytes, including headers and body |
| `MAX_RESPONSE_BODY_BYTES` | 16777216 bytes (16 MiB), the hard ceiling for `max_response_bytes` |
| `MAX_ERROR_BODY_BYTES` | 65536 bytes: error envelope size, and room beyond `max_body` for error envelopes |
| `MAX_RESPONSE_HEADER_BYTES` | 8192 bytes for serialized status line and headers |
| `MAX_RESPONSE_WIRE_BYTES` | 16 MiB body plus header bytes, the wire size bound |
| `MAX_RESPONSE_POOL_BYTES` | 67108864 bytes (64 MiB), the ceiling for `max_pool_bytes` |
| `RESPONSE_CHUNK_BYTES` / `MAX_POOL_CHUNKS` | 16384 bytes per pooled chunk / pool capacity in chunks (`MAX_RESPONSE_POOL_BYTES` / chunk size) |
| `MAX_RESPONSE_HEADERS` | 16 headers |
| `MAX_HEADER_NAME_BYTES` / `MAX_HEADER_VALUE_BYTES` | 64 / 256 bytes |
| `MAX_CONTENT_TYPE_BYTES` | 128 bytes |
| `MAX_ROUTES` | 64 routes |
| `MAX_METHOD_BYTES` / `MAX_ROUTE_PATTERN_BYTES` | 16 / 512 bytes |
| `MAX_PATH_PARAMS` | 16 parameters |
| `MAX_ALLOW_BYTES` | `MAX_HEADER_VALUE_BYTES` |
| `MAX_QUERY_FIELD_BYTES` | 1024 decoded bytes per field |
| `MAX_EVENT_LISTENERS` / `MAX_QUEUED_EVENTS` | 64 listeners / 256 queued events |
| `MAX_WORKERS` | 256 worker processes (`ServerConfig.workers`) |

The original `MAX_REQUEST` name remains as an alias of `MAX_REQUEST_BYTES`.
`INVALID_SUBSCRIPTION` is the failed subscription ID returned when the table is full.
Constants can also size application-owned fixed arrays at compile time.

## Runtime defaults and lifecycle

[Runtime constants](../src/constants/runtime.goose) supply the defaults used by
`server_config()`: `DEFAULT_PORT`, `DEFAULT_PUBLIC_BIND`, `DEFAULT_MAX_CLIENTS`,
`DEFAULT_MAX_REQUEST_BYTES`, `DEFAULT_READ_TIMEOUT_MS`, `DEFAULT_WRITE_TIMEOUT_MS`,
`DEFAULT_POLL_TIMEOUT_MS`, `DEFAULT_SHUTDOWN_GRACE_MS`, `DEFAULT_IDLE_TIMEOUT_MS`,
`DEFAULT_KEEP_ALIVE`, `DEFAULT_MAX_REQUESTS_PER_CONNECTION`, `DEFAULT_MAX_RESPONSE_BYTES` (1 MiB),
`DEFAULT_MAX_POOL_BYTES` (8 MiB), `DEFAULT_HANDLE_SIGNALS`, and `DEFAULT_WORKERS` (1, a single process).
`UNLIMITED_REQUESTS` disables the response-count shutdown trigger.

Use `ServerConfig` to select runtime values within the fixed limits. `DEFAULT_*`
constants describe initial settings; `MAX_*` constants describe upper bounds.
`MIN_PORT`, `MAX_PORT`, `MAX_TIMEOUT_MS`, and `MAX_POLL_TIMEOUT_MS` describe validation
bounds. Lifecycle callbacks receive `SERVER_STARTED`, `SERVER_STOPPING`, or `SERVER_STOPPED`;
with worker processes only the parent calls them (see [worker processes](api.md#worker-processes)).

Transport-prefixed `GW_*` names belong to the native implementation. A boundary
test checks that its client capacity agrees with the public Goose constant, and a
response test fills every declared header/body capacity to verify wire-buffer fit.
