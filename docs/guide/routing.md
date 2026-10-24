# Routing

Routes are declared inside `c.routes()`. The block is evaluated once to match the request and
again to dispatch the selected route, so keep code outside route bodies declarative. Route handlers
run only on the dispatch pass.

Unless marked complete, examples are fragments for an app that has imported Goose Web as
`goose_web` in its root source file and are shown inside `fn app(c: web::Ctx&)`.

```goose
fn app(c: web::Ctx&) {
    c.routes() {
        c.get("/health") { c.text("ok"); };
        c.get("/users/:id") { c.text(c.param("id")); };
        c.post("/users") { c.status(web::HTTP_CREATED).text("created"); };
    };
}
```

The DSL supports `get`, `post`, `put`, `patch`, `delete`, `head`, `options`, and `any`. Static
segments match before named parameters, and a method mismatch on the winning path shape returns
405 instead of falling through to a less specific route. Explicit HEAD routes win; otherwise GET
can handle HEAD.

## Groups and path parameters

Use `c.group(prefix)` to add a prefix to nested paths. Nested groups compose. This route-block
fragment assumes `UserView` is a struct with an `id` field:

```goose
c.routes() {
    c.group("/api") {
        c.group("/v1") {
            c.get("/users/:id") {
                c.json(UserView { id: c.param("id") });
            };
        };
    };
};
```

This registers `/api/v1/users/:id`. A `:name` parameter consumes one nonempty path segment;
`c.param("id")` returns its bytes as sent. Path parameters are not percent-decoded. Use
`c.param_int`, `c.param_u64`, `c.param_uuid`, or `c.param_slug` when the value must satisfy one of
those types; invalid typed parameters write a 422 response. Keep each route pattern the same
between the match and dispatch passes.

A final wildcard captures the remaining nonempty path including slashes:

`*name` route wildcards were added on `main` after `v0.6.0`; use a local checkout for this route
form. The published release supports named single-segment parameters.

```goose
c.get("/files/*path") { c.text(c.param("path")); };
```

For example `/files/docs/guide.txt` binds `path` to `docs/guide.txt`. Wildcards must be the final
segment and are not decoded. Routes can also be scoped by `c.host("api.example.com")` or
`c.host("*.example.com")`; see the routing reference for matching details.

## Query values

For one value, use `c.query("key")` or `c.query_int("page", 1)`. For a set of typed parameters,
bind a struct with `query<T>(c)`:

```goose
struct Search { q: u8[..64] = "", page: i32 = 1 }

c.get("/search") {
    let search, ok = query<Search>(c);
    guard ok else { return; }
    c.json(search);
};
```

The generic call is a plain function call, not `c.query<Search>()`. A missing key keeps its field's
default. Invalid binding writes a 400 response; rule-based 422 validation is a `main` feature and
is not part of `v0.6.0`. See
[typed query strings](../api.md#typed-query-strings).

## Common routing mistakes

- Do not calculate mutable values or perform side effects in the routes block outside handlers: it
  runs twice.
- Declare routes consistently on both passes; branching route declarations on request-mutated
  state can make matching and dispatch disagree.
- Parameters match one segment only. Use a final `*name` wildcard for a remainder containing `/`.
- A route body `return` exits the enclosing app function, so use it only when ending that request.

See [Routing DSL](../api.md#routing-dsl) for the complete rules and [Routes and query values](../api.md#routes-and-query-values)
for the lower-level router contract.
