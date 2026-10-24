# Requests and responses

This guide targets the current checkout. Basic typed JSON, query and form binding is in `v0.6.0`;
automatic field validation, `body_decode`, and `validate_result` were added on `main` after that
release.

The application context (`web::Ctx&`) exposes request data and response helpers. Most route code
uses the context methods through Goose's UFCS syntax: `c.method()`, `c.path()`, `c.target()`,
`c.header(name)`, `c.param(name)`, and `c.query(name)`.

Examples are fragments for an app that has imported Goose Web as `goose_web` in its root source
file; route examples belong inside `fn app(c: web::Ctx&)` and `c.routes() { ... }`.

## Return a response

Use `c.text` for plain text, `c.html` for HTML, and `c.json` for a struct or scalar. Set the status
before writing the body:

```goose
struct Created { id: i64 }

c.post("/items") {
    c.status(web::HTTP_CREATED).json(Created { id: 42 });
};
```

Use `c.json_list(items)` for an array or slice. `c.json` does not accept an array. To send no body,
call `c.no_content()`. `c.fail(status, code, message)` writes the standard JSON error envelope:

```goose
c.fail(web::HTTP_NOT_FOUND, "not_found", "Item not found");
```

The resulting body is `{"error":{"code":"not_found","message":"Item not found"}}` plus a
newline. Existing status is preserved by `c.json`; the default is 200. Responses exceeding the
configured body limit become a 500 `response_too_large` error. See [JSON responses](../api.md#json-responses-and-request-bodies)
and [HTTP and headers](../api.md#http-and-headers).

## Decode a JSON request

Define a struct, then use `body<T>(c)`. The following route fragment assumes `NewNote` is the type
shown in the snippet. The framework checks the content type, decodes strict JSON,
and runs validation rules registered for the type. On failure, it has already written the error
response; return from the route.

```goose
struct NewNote { title: u8[..80], pinned: bool = false }

c.post("/notes") {
    let note, ok = body<NewNote>(c);
    guard ok else { return; }
    c.status(web::HTTP_CREATED).json(note);
};
```

Wrong media type returns 415. Empty or malformed JSON returns 400. Invalid fields or constraints
return 422 with structured detail. Unknown and duplicate keys are errors. Struct text capacities
count UTF-8 bytes; validation string lengths count Unicode code points.

## Decode-only helpers and PATCH

`body_result<T>(c)` returns `T, DecodeResult` and does not run field validation. Use this when you
need decode metadata, for example to distinguish an omitted PATCH field from one supplied with its
default value. To validate the decoded data, use `body_decode<T>` with `validate_result`:

```goose
struct NotePatch { title: u8[..80] = "" }

c.patch("/notes/:id") {
    var patch, result = web::body_decode<NotePatch>(c);
    guard web::validate_result(c, "body", patch, result) else { return; }
    if web::has<NotePatch>(result, "title") {
        // Apply the explicitly supplied title.
    }
    c.no_content();
};
```

`body_decode` writes syntax and media errors immediately. `validate_result` combines schema issues
with field rules. The analogous `query_result<T>` is a binding-only helper; it does not validate
rules. Direct `json_decode<T>` is also decode-only. See [JSON codec](../api.md#json-codec) and
[validation](../api.md#validation).

## Query strings and forms

For individual values, `c.query(key)` returns a decoded query value and `c.query_int(key, fallback)`
parses an integer. For a group of fields use `query<T>(c)`, as in the
[routing guide](routing.md#query-values).

URL-encoded form bodies use `form<T>(c)`. This route fragment is complete once placed in a
`c.routes()` block inside an app:

```goose
struct NoteForm { title: u8[..80] = "" }

c.post("/notes/form") {
    let fields, ok = form<NoteForm>(c);
    guard ok else { return; }
    c.text(fields.title);
};
```

`form<T>` expects `application/x-www-form-urlencoded`; multipart forms are not supported. A wrong
content type returns 415 and malformed fields return 400. Query and form binding accept the same
scalar types and enforce unknown/duplicate-key checks. See [typed queries](../api.md#typed-query-strings)
and [forms](../api.md#forms).

## Errors and response headers

Use `c.set(name, value)` to set a response header. `c.status(code)` and `c.set(...)` return the
context and can be chained with a response writer. For errors, prefer `c.fail` so clients receive a
consistent envelope. The lower-level `web::application_error` helper is available when working
directly with a `Response`.

The reference documents accepted headers, body capacity behavior, application error escaping, and
HTTP parser errors in [HTTP and headers](../api.md#http-and-headers) and
[Middleware and application errors](../api.md#middleware-and-application-errors).
