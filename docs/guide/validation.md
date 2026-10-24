# Validation

**Version:** Rule-based request validation and validated settings are current `main` features;
they are not in the published `v0.6.0` package. Use a local checkout to follow these examples.

Goose Web validates typed request data after decoding when using `body<T>`, `query<T>`, or
`form<T>`. Declare constraints once in a `web::rules` overload for the struct:

The snippets assume Goose Web is imported as `goose_web` in the program's root file. Route
examples are fragments for `fn app(c: web::Ctx&)`.

```goose
struct CreateNote { title: u8[..80], priority: i64 = 0 }

fn web::rules(v: CreateNote&, r: web::Rules&) {
    r.field("title").required().min_len(1).max_len(80);
    r.field("priority").ge(0).le(5);
}
```

Then bind as usual. This route fragment uses the struct above:

```goose
c.post("/notes") {
    let note, ok = body<CreateNote>(c);
    guard ok else { return; }
    c.status(web::HTTP_CREATED).json(note);
};
```

On constraint failure, the framework writes a 422 response with the first error in the
`error.message` and structured entries in `detail`. No input values are included. Decode failures
have their own statuses: malformed JSON and query/form binding errors are 400, while unsupported
media types are 415.

## Available rules

- Text: `min_len`, `max_len` (Unicode code points, with byte capacity still enforced by the field),
  `pattern`, and `format`.
- Lists: `min_items` and `max_items`.
- Numbers: `ge`, `gt`, `le`, `lt`, and positive integer `multiple_of`.
- Query/form booleans: `lax()` accepts `yes`/`on` and `no`/`off` in addition to the normal boolean
  spellings. JSON boolean decoding stays strict.

Supported pattern identifiers are `PATTERN_SLUG`, `PATTERN_UUID`, `PATTERN_ASCII_ALNUM`,
`PATTERN_DIGITS`, and `PATTERN_HEX`. Formats are `FORMAT_EMAIL` (a pragmatic ASCII subset) and
`FORMAT_URI` (HTTP/HTTPS URL check). Empty text skips pattern and format checks. Empty string is
allowed by `required()`; combine it with `min_len(1)` when blank text is invalid.

## Optional fields and PATCH

An optional field omitted from the input keeps its declared default and skips that field's rules.
This supports partial updates. Use `body_decode<T>` and `validate_result` when you need both
validation and presence metadata:

```goose
struct NotePatch { title: u8[..80] = "" }

fn web::rules(v: NotePatch&, r: web::Rules&) {
    r.field("title").min_len(1).max_len(80);
}

c.patch("/notes/:id") {
    var patch, result = web::body_decode<NotePatch>(c);
    guard web::validate_result(c, "body", patch, result) else { return; }
    if web::has<NotePatch>(result, "title") {
        // Apply the title because the client supplied it.
    }
    c.no_content();
};
```

`required()` means the key must be present; it does not mean a nonempty string. `body_result<T>`
and `query_result<T>` provide decode/binding metadata without running validation. See
[decode-only helpers](requests-and-responses.md#decode-only-helpers-and-patch).

## Check rule tables and nested models

Check the table during startup to catch unknown/duplicate fields, contradictory bounds, lengths
that exceed field capacity, invalid identifiers, and nonpositive multiples:

```goose
import std;

fn main() {
    let rules_ok, rules_error = web::check_rules<CreateNote>();
    if !rules_ok { abort(rules_error); }
}
```

For nested structs, register their decoder and validation traversal as described in
[JSON responses and request bodies](../api.md#json-responses-and-request-bodies) and
[Validation](../api.md#validation). A `normalize(v: T&)` hook runs before field checks, and
`validate_model(v: T&, out: web::Issues&)` can add cross-field errors after field checks pass.

See the [validation reference](../api.md#validation) for the full error envelope, limits, nested
locations, hook signatures, and schema behavior.
