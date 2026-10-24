# Troubleshooting

Start with `python3 manage.py toolchain`, the full compiler error, the entry source path and the
framework revision. [Compiler setup](../ci.md) records the supported pin; Linux is tested in CI,
while other POSIX targets are not yet verified to the same level.

## The compiler is missing or cannot import std

`manage.py` uses `GOOSE`, or `goose` on PATH. Setting `GOOSE` does not change PATH for bare `goose`
commands. For the repository bootstrap, set both:

```sh
export GOOSE="$PWD/build/tools/goose/build/goose"
export GOOSE_STDLIB="$PWD/build/tools/goose/source/stdlib"
python3 manage.py toolchain
```

An out-of-tree compiler needs the source standard library path. Install a C compiler and Git too;
SQLite examples additionally need SQLite headers/libraries. Do not substitute the runtime hash
for a compiler Git revision: they identify different things.

## A new starter says settings or rules are unknown

Its framework source is older than its template. Current starters use unreleased APIs and default
to the checkout that generated them. An explicit `--source aurthurm/goose-web@v0.6.0` cannot supply
those APIs. Generate from a matching release checkout or keep the current local dependency.
See [project commands](project-tooling.md).

## The linker cannot find a cached native object

Keep `GOOSE_HOME` absolute, particularly when tests build in temporary directories:

```sh
export GOOSE_HOME="$PWD/build/fresh-cache"
python3 manage.py build
```

A fresh cache avoids stale compiler artifacts. Keep it separate by compiler revision and C
compiler. Preserve application databases when removing build outputs; `build/` can contain both.

## A generic helper does not compile

Write `body<Note>(c)`, not `c.body<Note>()`: Goose UFCS does not accept explicit type arguments.
Nested structs require registrations for the operations used: JSON decoding, encoding, validation,
schema generation or template field traversal. Use the registrations in the relevant guide and
check that your root file declares every imported package. See [JSON bodies](requests-and-responses.md)
and [project structure](project-structure.md).

## A request returns 400, 415 or 422

400 identifies malformed input/binding; 415 means the media type is wrong. Use
`Content-Type: application/json` for typed JSON bodies or
`application/x-www-form-urlencoded` for forms. Schema and field constraints return 422. Inspect
`detail` and its field locations on current main. A missing `required()` field differs from an
empty string; add `min_len(1)` to reject empty text. Return from handlers when binding fails.

## Routes behave differently after adding a wrapper

Route declarations are evaluated in multiple passes. Keep the same paths/groups on every pass,
and perform side effects inside handler bodies. Middleware that omits its continuation stops the
inner chain. For final-response work, remember that after-work runs in reverse nesting order.
See [routing](routing.md) and [middleware](middleware.md).

## State differs between worker processes

Globals, event buses and scheduler tables are per worker. Use the shared store for small volatile
values and SQLite for durable data. Never inherit a live SQLite handle through fork. See
[shared state](shared-state.md) and [deployment](deployment.md).

## Swagger UI is blank, or a stream appears to hang

`/docs` loads Swagger UI from a CDN and needs an appropriate Content Security Policy. Generated
JSON at `/openapi.json` works without that browser asset. For SSE use `curl -N`; it is a persistent
stream. Check proxy buffering and timeouts, and use client reconnection logic. Ordinary HTTP
responses should be read by their framing, not by assuming one socket read is a full response.

If a problem remains, include a minimal app, OS, compiler source revision, native compiler,
framework revision, command and complete error. Remove secrets before posting an issue.
