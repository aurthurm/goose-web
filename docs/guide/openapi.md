# OpenAPI

Goose Web can generate an OpenAPI 3.1 document and a Swagger UI page from the same route block.
This feature is available in `v0.6.0`; rule-derived validation constraints in the schema require
current `main`.

Wrap the routes with `web::openapi`. Put an annotation immediately before the route it describes;
each annotation applies to the next route only.

```goose
import goose_web from "../goose-web";

struct Todo { id: i64, title: u8[..80], completed: bool }
struct NewTodo { title: u8[..80], completed: bool = false }
struct TodoFilter { limit: i64 = 20 }

fn web::json_put_value(out: u8[>..]&, v: Todo&) -> bool {
    return web::json_put_fields(out, v);
}
fn web::optional_fields(v: NewTodo&) -> const u8[:] { return "completed"; }

var todos: Todo[..32] = [];

fn app(c: web::Ctx&) {
    web::openapi(c, web::OpenApiInfo {
        title: "Notes API", version: "1.0.0", description: "A small example"
    }) {
        c.routes() {
            web::summary(c, "Create a todo");
            web::accepts<NewTodo>(c);
            web::returns<Todo>(c, web::HTTP_CREATED);
            c.post("/todos") {
                let input, ok = body<NewTodo>(c);
                guard ok else { return; }
                guard todos.len < 32 else {
                    c.fail(web::HTTP_CONFLICT, "todos_full", "Todo list is full");
                    return;
                }
                let todo = Todo { id: todos.len as i64 + 1, title: input.title,
                    completed: input.completed };
                todos.push(todo);
                c.status(web::HTTP_CREATED).json(todo);
            };

            web::summary(c, "List todos");
            web::query_params<TodoFilter>(c);
            web::returns_list<Todo>(c, web::HTTP_OK);
            c.get("/todos") {
                let filter, ok = query<TodoFilter>(c);
                guard ok else { return; }
                guard filter.limit >= 1 && filter.limit <= 32 else {
                    c.fail(web::HTTP_UNPROCESSABLE_CONTENT, "bad_limit", "limit must be between 1 and 32");
                    return;
                }
                var page: Todo[..32] = [];
                for i in todos.len { if i < filter.limit { page.push(todos[i]); } }
                c.json_list(page[..]);
            };
        };
    };
}
```

The document is served at `/openapi.json`; Swagger UI is at `/docs`. `OpenApiInfo` can override
`json_path` and `docs_path`. If `openapi` does not wrap the route block, those paths are ordinary
404s. In the describe pass, Goose evaluates the routes block again but does not run route bodies.
Keep route declarations stable and leave side effects inside handlers.

## Schemas and their limits

`accepts<T>` documents a required JSON request body. `returns<T>` describes one response status,
`returns_list<T>` an array response, `returns_empty` a response such as 204, and
`query_params<T>` the fields of a query struct. Use `web::summary` and `web::tag` before the route.
Generic annotations use the explicit `web::` form because Goose UFCS does not take type arguments.

Schemas are inline and built from reflected fields. Declared defaults alone do not make a field
optional. Without a validation rule, list optional request fields with `web::optional_fields`;
when a field has a rule on current `main`, that rule's `.required()` setting controls whether the
schema marks it required. Query fields are optional unless their rules require them.

Nested structs need a schema registration:

```goose
struct Address { city: u8[..40] }
fn web::json_schema_value(out: u8[>..]&, v: Address&) {
    web::json_schema_fields(out, v);
}
```

This is the OpenAPI registration. If the app also decodes or encodes nested JSON, it needs the
separate `json_read_value` / `json_put_value` registrations described in the
[JSON API](../api.md#json-responses-and-request-bodies).

Generated schemas describe reflected types and supported bounds. They do not infer arbitrary
handler checks, business rules, or constraints beyond the supported schema fields. Document those
with the summary/description or a hand-maintained contract. `any()` routes are omitted; one schema
is documented per request body. The full behavior and size limits are in the
[OpenAPI reference](../api.md#openapi).

## Swagger UI and Content Security Policy

The built-in `/docs` page loads Swagger UI assets from a pinned `cdn.jsdelivr.net` URL, so a browser
needs access to that host. The default `secure_headers` CSP blocks those scripts. If you apply that
middleware to the app, configure a policy that permits the required CDN assets. An empty
`content_security_policy` omits CSP for responses inside that wrapper, so an app-wide wrapper omits
it for every response it wraps. See [secure headers](../api.md#middleware).
