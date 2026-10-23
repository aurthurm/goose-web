# Supported HTTP request profile

Goose Web implements a restricted HTTP/1.1 origin server profile. This document
describes the parser's acceptance contract; it is **not a claim of full HTTP
conformance**. `tests/unit/http_parser.goose` checks this contract with runtime
bounds checks enabled, alongside the core and live socket tests.

## Request line and target

The request line uses exactly `method SP target SP HTTP/1.1 CRLF`. The method
must be a nonempty HTTP token and remains case-sensitive. A syntactically valid
`HTTP/DIGIT.DIGIT` version other than `HTTP/1.0` or `HTTP/1.1` receives 505; malformed
version syntax receives 400. Unsupported methods can reach routing and receive 405.

Only origin-form targets are supported: an absolute path beginning with `/`,
optionally followed by `?` and a query. Literal bytes must belong to the ASCII
URI path/query grammar. Percent escapes require two hexadecimal digits. Escaped
bytes are preserved without decoding or normalization; `%00`, `%2f`, and encoded
UTF-8 are syntactically valid. Raw non-ASCII, fragments (`#`), controls, backslash,
and other characters outside that grammar receive 400. Absolute-form,
authority-form, and asterisk-form are outside this profile and receive 400.

These choices follow the request-line and origin-form grammars in
[RFC 9112 sections 2.3 and 3](https://www.rfc-editor.org/rfc/rfc9112.html#section-3)
and URI character rules in
[RFC 3986 sections 2 and 3](https://www.rfc-editor.org/rfc/rfc3986.html#section-2).
Optional lenient whitespace parsing is deliberately not implemented.

## Headers and Host

Headers require CRLF line endings and token field names immediately followed by
`:`, without preceding whitespace. Bare LF, bare CR followed by a non-LF byte,
obsolete folded lines, NUL, DEL, and controls other than HTAB receive 400.
Optional whitespace around values is exclusively SP and HTAB. Other header
values can retain opaque bytes from `0x80` through `0xff`.

HTTP/1.1 requires exactly one nonempty Host. HTTP/1.0 may omit Host, as RFC 9112 allows;
a Host field that is present must still be valid. Accepted hosts are URI registered names
(unreserved characters, sub-delimiters, and valid percent escapes) or bracketed
IPv6 literals, optionally followed by a decimal port from 0 through 65535.
IPv6 supports one compression marker and a valid final IPv4 tail. A port must
contain at least one digit. Leading zeroes in ports are accepted. Names are not
resolved or normalized; DNS existence and ownership are application concerns.
Whitespace inside a host, user information, unbracketed IPv6, malformed IP
literals, malformed percent escapes, and invalid ports receive 400.

The Host grammar comes from
[RFC 9110 section 7.2](https://www.rfc-editor.org/rfc/rfc9110.html#section-7.2)
and [RFC 3986 sections 3.2.2–3.2.3](https://www.rfc-editor.org/rfc/rfc3986.html#section-3.2.2).
This profile additionally excludes empty host names, empty ports, IPvFuture,
IPv6 zone identifiers, and ports above 65535. Those exclusions restrict the URI
grammar to the server's supported address forms.

## Framing and capacity

Content-Length accepts decimal digits with SP/HTAB around the value. Many leading
zeroes are accepted without integer overflow. Empty, signed, comma-separated,
duplicated, or otherwise malformed lengths receive 400. A valid length exceeding
the available request capacity receives 413. Length accumulation saturates at the
limit while continuing to validate all remaining digits.

Transfer-Encoding together with Content-Length receives 400. Transfer-Encoding
alone is unsupported (501), and Expect is unsupported (417). Chunk decoding and
trailers are not implemented. These conservative choices avoid ambiguous framing;
see [RFC 9112 section 6](https://www.rfc-editor.org/rfc/rfc9112.html#section-6).

The total request buffer is 8192 bytes, including the request line, headers,
separator, and body. A header section without a complete separator at capacity
receives 431; an oversized buffer with a complete header section receives 413.
An exactly full valid request is accepted. Otherwise, valid prefixes return 0
until the declared body is complete. A trailing header CR remains incomplete
until the following byte arrives. Detected malformed line endings can fail
before the complete header section arrives.

Bodies are opaque binary data and can contain any bytes, including CRLFCRLF.
They are never scanned as headers. Missing Content-Length means an empty body.
The parser exposes borrowed slices valid while the caller's input remains alive
and unchanged. The server completes its handler before reusing that buffer.

## Server-sent event responses

The only chunked responses the server produces are server-sent event streams started with
`c.sse(channel)`. Such a response is HTTP/1.1 only, answers GET requests only, and sends
`Transfer-Encoding: chunked` with no Content-Length. Each event is one chunk, and the stream ends
with the terminating chunk `0`, after the `event: close` message, when the server shuts down. A
heartbeat is the chunk for the comment `: ping`. HTTP/1.0 and HEAD requests asking for a stream get
400. Trailers are never sent. Clients that send bytes on a stream are not parsed: the bytes are
discarded. Other responses keep Content-Length framing.

## Connection and error boundaries

Connections persist by default. Keep-alive rules:

- HTTP/1.1 persists unless the client sends `Connection: close`.
- HTTP/1.0 persists only with `Connection: keep-alive` and no `close` token.
- A persistent response carries no `Connection` field. A closing response carries
  `Connection: close`. A 1.0 client that kept the connection gets `Connection: keep-alive`.
- Requests are processed strictly in order. Bytes that arrive pipelined behind a
  complete request stay buffered and are parsed after its response is fully written.
- The server closes after a parser error, after `max_requests_per_connection` responses
  (that last response says close), during shutdown (the in-flight response completes
  first), and when `keep_alive` is false.
- Read deadlines apply per request from its first byte. An idle connection that sends
  nothing within `idle_timeout_ms` closes silently, with no response.

Streaming bodies other than server-sent events, CONNECT tunnels, TLS, and HTTP/2 are outside this
profile. Parser errors bypass application middleware and use the server's parser error
response; application JSON errors are a separate layer. For inputs containing
multiple independent faults, the parser returns the first detected failure,
except that Transfer-Encoding plus a syntactically valid Content-Length always
receives 400 even when that numeric length exceeds capacity.
