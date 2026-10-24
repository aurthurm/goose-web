# Security controls

**Version:** Cookie sessions, CSRF, `secure_headers`, and per-process `rate_limit` are present in published `v0.6.0`.
The password hashing/authentication APIs and several operations middleware described here are on
`main`, not that published package. `SessionConfig.store`, shared-store sessions, worker-wide rate
limits and cross-worker state are also `main`-only. The pages example contains a demo-only secret.

Security middleware is opt-in. Add it deliberately to routes that need it, and keep secrets out
of source code. The framework provides password hashing and verification, Basic/Bearer
authentication, signed cookie sessions, CSRF checks, secure response headers, bounded rate
limiting, request body limits and trusted proxy handling. See the [pages example](../../examples/pages/server.goose)
for a demo form/session flow; its embedded secret is explicitly for demonstration only.

For HTML forms, use secrets of at least 32 bytes for sessions and CSRF; use separate keys when
possible. This complete middleware fragment demonstrates session/CSRF wiring only: `/save` stores
`user=alice` in the session, but it does not authenticate a login. The sample uses `secure: false`
so the cookie works against a local plain-HTTP server:

```goose
import goose_web from "../goose-web";
import std;
import os;

const APP_SECRET = "local-session-demo-secret-0123456789abcdef"; // local demo only

fn app(c: web::Ctx&) {
    session(c, web::SessionConfig { secret: APP_SECRET, secure: false }) {
        csrf(c, APP_SECRET, true) {
            c.routes() {
                c.get("/form") {
                    c.html(str("<form method=post action=/save><input type=hidden name=csrf_token value=\"",
                        c.csrf_token(), "\"><button>Save</button></form>"));
                };
                c.post("/save") {
                    if !c.session_set("user", "alice") {
                        c.fail(web::HTTP_INTERNAL_SERVER_ERROR, "session_error", "Could not save session");
                        return;
                    }
                    c.text("saved");
                };
                c.get("/me") { c.text(c.session_get("user")); };
            };
        };
    };
}

fn main() {
    var config = web::server_config();
    config.handle_signals = true;
    let started = web::run(config) { c => app(c) };
    if !started { abort("server failed"); }
}
```

`session` signs a small cookie-held key/value payload (16 entries). It is signed,
not encrypted: clients can read its contents, so store only non-sensitive values. `session_clear`
clears the current browser session, but a copied old cookie remains valid until expiry. Server-side
sessions via `SessionConfig.store` keep values in the shared store, which is volatile and bounded.
Neither mode is a durable session database.

In production, obtain the key from a secret source at startup rather than embedding it and set
`secure: true` when HTTPS reaches the browser (typically through a TLS-terminating proxy). The
browser will not send that session cookie over ordinary HTTP. The CSRF cookie in this implementation
does not carry `Secure`, so forms must still be served only over HTTPS. With `check_origin = true`,
the browser's `Origin`/`Referer` host must match the request `Host`; configure the proxy to preserve
that relationship.

CSRF middleware issues a double-submit token; unsafe requests must echo it in the
`X-CSRF-Token` header or `csrf_token` form field. This does not replace authentication, authorization,
or output escaping. Check `c.auth_subject()` only after Basic or Bearer middleware verified the
request. Password hashes use PBKDF2-HMAC-SHA256; token signing is a framework-specific HMAC format,
not JWT.

Only trust forwarded client addresses from known proxy peers. `trust_proxies` allow-lists proxy
addresses; otherwise forwarded headers are ignored. `secure_headers` can add CSP and optional
HSTS, but choose a CSP that fits the application. Rate limits are bounded and per client address;
with multiple workers, the shared store makes limits common to that server instance by default.

The framework does not provide a general authorization policy, encrypted session cookies, TLS
termination, or durable cross-host session storage. Put TLS at a trusted reverse proxy, configure
that proxy's address explicitly, and enforce access checks in handlers. Review the detailed
limitations for [sessions](../api.md#sessions), [CSRF](../api.md#csrf),
[authentication](../api.md#authentication), and [trusted proxies](../api.md#trusted-proxies).
