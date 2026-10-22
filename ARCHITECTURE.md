# Architecture notes

## Layers

1. **Application:** declarative route composition, handlers and typed extractors.
2. **Core (Goose):** dispatch, request parsing, response formatting, middleware, errors and policies.
3. **Transport adapter:** sockets, timeouts, read/write and connection lifecycle through a small C ABI.
4. **OS:** sockets / polling primitives.

### Bootstrap constraints

The transport experiment is synchronous, POSIX-only and one connection at a time. The socket shim never retains pointers to Goose-owned buffers. The native `gw_read` and `gw_write` APIs consume Goose slices immediately. There is no background task or callback into Goose. No keep-alive, streaming or request bodies are supported in the bootstrap demo.

The initial routing utility is deliberately independent of the socket implementation so that core behavior can be tested without networking.

### Route dispatch design

Goose's callable blocks are compile-time constructs and cannot escape as ordinary function pointers. Therefore **do not** build a runtime registry of arbitrary callbacks. Investigate a compile-time route table or generated static dispatcher. Route matching should be deterministic, resolve static-before-parameter precedence, and reject ambiguous registrations.

### HTTP safety requirements before alpha

- Header/body/time/connection limits, reject conflicting content-length and transfer-encoding.
- Incremental parsing across reads. Correct CRLF handling, path normalization, percent decoding and routing rules.
- No response splitting, constant-time comparison for secrets, and safe default headers.
- Backpressure and bounded queues; handle partial reads/writes and client disconnects.
- Fuzz request parser and verify against established HTTP test corpora.
- TLS provided by a trusted reverse proxy until a native adapter is complete.

### Plugin contract

Plugins operate on compile-time route configuration or per-request context, not arbitrary mutable process-global state. Transport plugins are distinct from application middleware. Version public contracts independently.

### Versioning

Experimental `0.x` versions may change APIs. Every release pins an upstream Goose compiler revision, tests supported OS/compilers and includes a compatibility matrix.
