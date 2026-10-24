# Middleware

Middleware wraps the work for a request. The framework's built-in middleware is called with a
block:

Examples assume Goose Web is imported as `goose_web` in the program's root file. The first snippet
is a complete app function; other route examples are fragments unless stated otherwise.

```goose
fn app(c: web::Ctx&) {
    request_id(c) {
        c.logger() {
            c.routes() {
                c.get("/health") { c.text("ok"); };
            };
        };
    };
}
```

The outer wrapper runs first before the route and last after it. In this example the order is:
`request_id` before, `logger` before, route, `logger` after, `request_id` after. A middleware that
does not call its continuation stops the inner chain. Built-ins include `request_id`, `logger`,
`json_logger`, `cors`, `require_json`, `rate_limit`, `body_limit`, `etag`, and security helpers; see
the [middleware reference](../api.md#middleware).

`json_logger`, `trust_proxies`, `body_limit`, `etag`, and `shed_load` were added on `main` after
`v0.6.0`. They are not available when importing the published release.

## Write a middleware wrapper

Define a generic function whose type parameter represents the continuation. Call `Next()` to run
the nested block. The following snippet is a complete app fragment:

```goose
import std;

fn timing<Next>(c: web::Ctx&) {
    print("request started: ", c.method(), " ", c.path());
    Next();
    print("request finished: ", c.response.status);
}

fn app(c: web::Ctx&) {
    timing(c) {
        c.routes() {
            c.get("/health") { c.text("ok"); };
        };
    };
}
```

`Next()` is a function-like continuation and may be called once. Omitting it short-circuits the
inner work. The response is available through `c.response`; methods such as `c.done()` can tell
whether an inner handler already wrote a response.

## Place middleware at the right level

Wrap `c.routes()` when a middleware should apply to every route. Place a wrapper inside a specific
route body when it should apply only to that route. For example, `require_json` is usually scoped
to body-carrying routes because it checks the request media type:

```goose
c.post("/notes") {
    require_json(c) {
        let note, ok = body<NewNote>(c);
        guard ok else { return; }
        c.status(web::HTTP_CREATED).json(note);
    };
};
```

Middleware can short-circuit with a response such as 401, 403, 413, or 429. Ensure the route code
returns after any helper that reports failure; otherwise it may continue and overwrite that
response.

For middleware that adds headers or inspects the final response, choose its position deliberately:
headers set before `Next()` can be replaced by inner code, while after-work observes the completed
inner response. Nested after-work runs in reverse order. Do not use a nonlocal `return` from inside
a callback if outer after-work must run.

For exact built-in behavior, including proxy trust ordering, CORS preflight, ETag, and rate limit
scope, see [Middleware](../api.md#middleware) and [Request logs, proxies, caching and load](../api.md#request-logs-proxies-caching-and-load).
