# Security

This page is the security review of Goose Web: the threat model, what the framework implements
and where, what it does not do, and the findings from reviewing the Goose security code and the
native C shims. The API contracts are in [api.md](api.md); this page says what they protect
against and what they leave to the application.

Read it with the [HTTP request profile](http-conformance.md), which states the parser rules.

## Threat model

Goose Web is a small HTTP/1.1 server library. Its job is to turn bytes from the network into a
validated request, run application code, and write a bounded response. Its security depends on
three things: the parser and limits accept only well-formed input, the helpers (sessions, CSRF,
templates, JSON, static files) make the safe choice the default, and the application uses them.

Assets:

- Application data reachable through routes, the SQLite layer and session values.
- Session cookies, CSRF tokens, passwords (as PBKDF2 hashes) and bearer tokens.
- Files outside the directories an application serves, and the process itself.

Adversaries considered:

- An unauthenticated remote client sending arbitrary bytes, slowly or in volume.
- A malicious web page driving a logged-in user's browser (cross-site request forgery, reflected
  or stored script injection, cross-origin reads).
- A client holding a valid session or token trying to reuse, alter or outlive it.
- A client trying to read files outside a served directory, or to smuggle headers into responses.
- Someone who can write a cookie into the victim's browser (for example from a sibling subdomain).

Trust boundaries and assumptions:

- The network-facing boundary is the parser (`src/http/request.goose`) and the transport shim.
- Application code, configuration, secrets and the contents of served directories are trusted.
  A static directory is configuration, not user input: write access to it is a deployment
  decision.
- The database file and the compiler are trusted.
- The entropy source is the kernel (`getrandom(2)`, then `/dev/urandom`).

Out of scope, and the application's or the deployment's job: TLS termination, global bandwidth and
connection-flood defence, account lockout, authorization rules, password policy, and the security
of any reverse proxy in front of the server.

## What is implemented

| Area | Mechanism | Where | Tests |
| --- | --- | --- | --- |
| Request parsing | Strict CRLF framing, token header names, validated targets and Host, one Content-Length, `Transfer-Encoding` refused (501), `Expect` refused (417), control bytes in values refused, 8 KiB request cap | `src/http/request.goose` | `tests/unit/http_parser.goose`, parser fuzz (33,119 checks) |
| Limits | Request bytes, header count and size, response body cap (1 MiB default, 16 MiB ceiling), serialized bytes in flight, client slots, JSON and form capacities, session and rate-table bounds | `src/constants/limits.goose`, `src/runtime/server.goose` config | `tests/unit/app_config.goose`, integration |
| Deadlines | `read_timeout_ms` runs from the first byte of a request until it is complete, so a trickled request is cut off. `write_timeout_ms` bounds a response. `idle_timeout_ms` closes idle keep-alive connections. Per-connection request caps | `src/runtime/server.goose`, `native/posix/transport.c` | `tests/integration/runtime.py` |
| Slow clients | Bounded client slots (64); a connection holds input memory only while it has bytes to parse; capacity rejections are counted | `native/posix/transport.c`, runtime | integration (idle keep-alive at `max_clients`) |
| Path traversal | Percent-decoding with refusal of encoded `/`, `\`, NUL and controls; `.` and `..` refused; hidden segments 404; empty segments refused; files must be regular and must resolve inside the directory (symbolic links included) | `src/app/static.goose`, `native/posix/system.c` (`gw_file_within`) | `tests/unit/static_files.goose`, `tests/native/system.c`, static fuzz |
| File size | Stat before read; a file over `max_body` is refused before any byte is read; reads are bounded to `size + 1` | `src/sys/files.goose`, `src/app/static.goose` | `tests/unit/static_files.goose` |
| Cookies | RFC 6265 cookie-octet check on values, token check on names, path check, `SameSite=None` requires `Secure`, CR/LF cannot enter a value | `src/app/cookies.goose` | `tests/unit/app_security.goose`, input fuzz |
| Sessions | HMAC-SHA256 over the payload under its own label, constant-time tag comparison before the payload is read, versioned bounded payload, issue time and expiry checked, issue times more than 60 s ahead refused | `src/app/session.goose` | `tests/unit/sessions.goose` |
| CSRF | Double-submit token that carries an HMAC tag, constant-time comparison, optional Origin/Referer host check, 403 `csrf_failed` | `src/app/csrf.goose` | `tests/unit/csrf.goose` |
| XSS in templates | `{{name}}` escapes `&`, `<`, `>`, `"` and `'`; `{{{name}}}` is raw and documented as such | `src/app/templates.goose` | `tests/unit/app_templates.goose`, template fuzz (exact match with `html_escape`) |
| JSON | Strict decoder with capacities; encoder escapes controls, quotes and backslashes; strings must be valid UTF-8 on both encode and decode | `src/json/codec.goose`, `json` stdlib | `tests/unit/json_codec.goose`, JSON fuzz |
| SQL | Values are bound with explicit lengths; no SQL is built from values; one statement per prepare | `db/native/sqlite_shim.c`, `db/*.goose` | `tests/unit/db.goose`, SQLite shim fuzz (ASan) |
| Rate limiting | Fixed window per TCP peer, 429 with `Retry-After`, table bounded at 1024 clients | `src/app/middleware.goose` | `tests/unit/app_security.goose` |
| Response headers | `secure_headers` (nosniff, DENY, referrer policy, CSP, optional HSTS). Every header path validates name and value; CR/LF refused in `set_header`, `append_header`, `set_cookie`, `redirect` and re-checked at serialization | `src/http/headers.goose`, `src/app/context.goose`, `src/http/response.goose` | `tests/unit/app_security.goose` |
| CORS | `Access-Control-Allow-Origin` only. No `Access-Control-Allow-Credentials` is ever emitted, so the wildcard can never be combined with credentials. A specific origin adds `Vary: Origin` | `src/app/middleware.goose` | `tests/unit/app_security.goose` |
| Open redirects | `redirect_local` accepts only a local absolute path (no scheme, no `//` or `/\` prefix, no controls). Plain `redirect` keeps its contract and is the caller's responsibility for user-supplied targets | `src/app/context.goose` | `tests/unit/app_security.goose` |
| Passwords | PBKDF2-HMAC-SHA256, 600000 iterations by default, 16-byte random salt, constant-time comparison, counts and salt lengths bounded at verification | `native/posix/crypto.c`, `src/app/auth.goose` | `tests/native/crypto.c` (RFC 7914 and published vectors), `tests/unit/auth.goose` |
| Basic and Bearer auth | Credentials checked by the application's check function; 401 with a challenge; the verified subject is the only identity `auth_subject` returns | `src/app/auth.goose` | `tests/unit/auth.goose` |
| Signed tokens | HMAC-SHA256 with a fixed label, a version byte, issue and expiry times, and no algorithm field (see below) | `src/app/auth.goose` | `tests/unit/auth.goose` |
| Randomness | `getrandom(2)`, then `/dev/urandom`. Failure is reported, and the caller refuses to issue a token or hash. A zero-length return counts as failure, not a retry | `native/posix/crypto.c`, `src/sys/crypto.goose` | `tests/native/crypto.c` |
| Process isolation | With `workers` above 1, each worker is a forked process with its own connection slots, so a crash or leak in one does not take the others. Linux workers get `SIGTERM` when the parent dies. Signals and reaps refuse pid 0 and negative pids | `native/posix/process.c`, `src/runtime/server.goose` | `tests/native/process.c`, `tests/integration/workers.py` |
| Listening | Loopback by default; the wildcard address needs `public_bind` | `native/posix/transport.c` | `tests/native/transport.c` |
| Logging | One line per request: method, path (no query string, no headers, no cookies), status and size. Control bytes are masked. Secrets are never logged | `src/app/middleware.goose` (`logger`) | `tests/unit/app_middleware.goose` |

### Password hashing

The encoded form is `$pbkdf2-sha256$<iterations>$<salt base64url>$<hash base64url>`, with a
16-byte salt and a 32-byte hash, both unpadded base64url. `hash_password` uses 600000 iterations,
the OWASP guidance for PBKDF2-HMAC-SHA256 in 2023. Verification reads the count from the stored
hash, so raising the default later does not invalidate old hashes. Counts above 10,000,000 are
refused, so a stored hash cannot be used to make verification expensive. The derived key is
compared in constant time, and key-pad material is wiped from the stack after use.

### Why signed tokens are not JWTs

A JWT names its signing algorithm in its own header. A verifier that trusts that header can be
made to accept `"alg": "none"` (no signature at all), or to verify an HMAC with a public key
that the attacker knows. Both failures come from letting the token choose how it is checked.

`sign_token` and `verify_token` have no such field. A token is
`base64url(payload) "." base64url(tag)`, with `tag = HMAC-SHA256(secret, "gw-token|" || base64url(payload))`
and the payload fixed to a version byte, issue time, expiry and subject. Verification always
computes the one HMAC, compares it in constant time, and only then reads the payload. Tokens are
bearer credentials with no revocation: anyone holding one can use it until it expires, so keep
the lifetime short and rotate the secret to sign everyone out.

## What is not implemented

- **TLS.** Terminate TLS at a reverse proxy and forward to Goose over loopback or a private
  network. `secure = true` on session and CSRF cookies, and HSTS, only make sense when the
  browser reaches the site over HTTPS.
- **HTTP/2 and HTTP/3.** Only HTTP/1.1 and HTTP/1.0 request framing is accepted.
- **Request body chunking.** A `Transfer-Encoding` request is refused with 501. Smuggling through
  ambiguous framing is therefore refused here, but a proxy in front must also not forward such
  requests. Forwarded headers (`X-Forwarded-For`, `Forwarded`) are never trusted.
- **Multipart bodies.** `form<T>` parses urlencoded bodies only.
- **Server-side session revocation.** A session cookie stays valid until `max_age`, even after
  `session_clear()` on another request. Server-side session storage is not part of this version.
- **Authorization.** Goose authenticates with `basic_auth` and `bearer_auth` when the application
  asks, and records the subject. Which subject may do what is the application's decision.
- **Login protection.** `rate_limit` is generic. Apply it to login routes with a limit suited to
  the application. There is no lockout and no breached-password check.
- **Global DoS protection.** Per-connection limits, deadlines and the client cap bound the work one
  connection can cause. Bandwidth exhaustion, connection floods and SYN floods need the network
  or the proxy.
- **Content Security Policy nonces.** The CSP is a configured string. Nonce generation is not
  provided.
- **Constant-time user lookup.** `verify_password` is constant-time in the comparison. A lookup of
  a user name that does not exist can return sooner than one that does, and the application's check
  function decides how much that matters.

## Findings

Severity follows the impact on a deployment that uses the default configuration. "Fixed" means the
change is in this tree with a regression test. "Accepted" means the behaviour is intended and
documented.

| # | Severity | Finding | Status |
| --- | --- | --- | --- |
| 1 | Medium | Static files followed symbolic links out of the served directory. The API docs said links were followed, which contradicts "never escapes the root" | Fixed. `gw_file_within` resolves real paths; a link that leaves the root answers 404. Links that stay inside still work. Tests: `tests/native/system.c`, `tests/unit/static_files.goose`, `tests/fuzz/static.goose` |
| 2 | Medium | `gw_kill` accepted pid 0 and -1, which signal the caller's process group or every process the user owns. `gw_wait_child` accepted them too, which reaps any child | Fixed. Both refuse pid <= 0. Tests: `tests/native/process.c` |
| 3 | Low-Medium | The JSON decoder accepted escapes such as `\uD800` that decode to bytes that are not UTF-8. The text was stored in a field, and the encoder then failed on it | Fixed. Decoded strings are checked for UTF-8 and refused with `invalid UTF-8 in string`. Tests: `tests/unit/json_codec.goose` (`test_surrogates`), JSON fuzz |
| 4 | Low | `redirect` accepts any `Location`, so a return URL taken from a request gives an open redirect | Mitigated. `redirect_local` accepts only local paths. `redirect` keeps its contract; the docs say user-supplied targets must go through `redirect_local`. Tests: `tests/unit/app_security.goose` |
| 5 | Low | `gw_random_bytes`: a `getrandom` return of 0 for a nonzero request would retry forever | Fixed. Zero is treated as failure and the call falls back to `/dev/urandom`, then reports failure. Tests: `tests/native/crypto.c` |
| 6 | Low | `gw_recv` and `gw_send` did not reject negative lengths, which convert to a huge `size_t` | Fixed. Refused before the system call. Tests: `tests/native/transport.c` |
| 7 | Low | CSRF Origin check compares the host only and ignores the scheme. A proxy that terminates TLS makes the scheme unreliable for this check | Accepted and documented in [api.md](api.md#csrf) |
| 8 | Low | Session and CSRF cookies do not set `Secure` by default, because local development runs over HTTP | Accepted and documented. Set `secure = true` in any HTTPS deployment |
| 9 | Low | The rate limit keys on the TCP peer. Behind a proxy, every client shares the proxy's bucket | Accepted and documented. The fix belongs in the proxy configuration, not in trusted forwarded headers |
| 10 | Low | Static file containment is checked, then the file is opened. A link swapped between the two steps could escape | Accepted and documented. Serve trees that only trusted writers can change |
| 11 | Info | Header injection: every response header path validates CR/LF, and `Set-Cookie` lines are built from validated tokens | Verified. Covered by `tests/unit/app_security.goose` and the cookie input fuzz |
| 12 | Info | Template escaping covers `& < > " '`; the output equals the escaped value for hostile inputs | Verified by the template fuzz (16,388 renders) |
| 13 | Info | CORS never emits `Access-Control-Allow-Credentials`, so wildcard with credentials is impossible | Verified and tested |
| 14 | Info | Constant-time comparison is used for CSRF tokens, session tags, token tags and password hashes. Lengths are public | Verified |
| 15 | Info | Randomness failure fails closed: CSRF answers 500, `hash_password` returns false, tokens are not signed | Verified |
| 16 | Info | Base64 length arithmetic `in.len * 4` could overflow only for slices above 2^61 bytes, which the runtime cannot produce | Not reachable |
| 17 | Info | Goose's JSON reader rejects raw control bytes (below 0x20) inside strings, as RFC 8259 requires | Verified against the stdlib source |
| 18 | Info | The libFuzzer harnesses found a bug in their own harness (a negative length for a one-byte input). The library returned an error as designed | Harness fixed; no library crash |
| 19 | Info | `gw_pipe_read_record` and `gw_pipe_write_record` treat a negative size as zero bytes, so a read reports end-of-file. Callers pass the fixed record size, so this is not reachable | Accepted; noted for any future caller that computes a size |

Findings 1 to 6 are the code changes in this review; each has a regression test in the suite.

## Verification

Fuzzing and property tests (deterministic seeds 1, 42, 20261022 and 3735928559 for the Goose
programs, run by `python3 tests/run.py`):

| Target | Program | Inputs |
| --- | --- | --- |
| HTTP parser | `tests/fuzz/parser.goose` | 33,119 |
| JSON decoder and encoder | `tests/fuzz/json.goose` | 16,387 decodes, 3,517 accepted and re-encoded, plus deep nesting and long input |
| Query, cookie, form | `tests/fuzz/input.goose` | 81,920 checks, 16,122 forms refused with an error response |
| Template rendering | `tests/fuzz/template.goose` | 16,388 renders, each equal to the escaped expectation |
| Static path resolution | `tests/fuzz/static.goose` | 16,384 paths, 2,434 served, all inside the root |

Native libFuzzer with AddressSanitizer (clang only; `tests/run.py` runs them for
`GOOSE_FUZZ_SECONDS`, default 10):

| Target | Harness | Run | Result |
| --- | --- | --- | --- |
| base64url, HMAC-SHA256, PBKDF2 | `tests/fuzz/native/codec_fuzz.c` | 2,688,328 runs in 61 s | No sanitizer findings |
| SQLite shim argument handling | `tests/fuzz/native/sqlite_fuzz.c` | 15,757,485 runs in 61 s | No sanitizer findings |

The first codec run stopped on an assertion in the harness itself (see finding 18). It was fixed,
and the reruns above are clean.

No run found a crash, an out-of-bounds access, or a case where a decoded or served value escaped
its input or its root.

### Running the native fuzzers without make

```sh
clang -std=c11 -g -O1 -fsanitize=fuzzer,address tests/fuzz/native/codec_fuzz.c -o build/codec_fuzz
build/codec_fuzz -max_total_time=60 -artifact_prefix=build/

clang -std=c11 -g -O1 -fsanitize=fuzzer,address tests/fuzz/native/sqlite_fuzz.c -lsqlite3 -o build/sqlite_fuzz
build/sqlite_fuzz -max_total_time=60 -artifact_prefix=build/
```

Run them from the repository root, after creating `build/`. A crash writes its input to
`build/crash-*`; reproduce it with `build/codec_fuzz build/crash-...`. `tests/run.py` prints a SKIP
line when clang or the sanitizer runtime is missing.

## Deployment checklist

- Serve over HTTPS through a proxy. Set `secure = true` on session and CSRF cookies, and send
  HSTS from `secure_headers`.
- Keep `public_bind` false unless the proxy is on another host.
- Load session and token secrets from the environment or a secret store. Use at least 32 random
  bytes, and never commit them.
- Use `redirect_local` for any target taken from a request.
- Use `check_origin = true` on `csrf` for state-changing routes that are reached from pages on
  other origins.
- Apply `rate_limit` to login routes, and set `max_age` on sessions to match the risk.
- Keep static directories free of files that only the application may write, and free of
  symbolic links to places an attacker could change.
- Keep the reverse proxy from forwarding ambiguous request framing.
