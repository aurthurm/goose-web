# Contributing

Goose Web is early-stage. File an issue before proposing new large APIs. Small fixes, compiler-compatibility reports and tests are welcome.

## Local development

1. Install the pinned upstream compiler from [aardappel/goose](https://github.com/aardappel/goose) (see [docs/ci.md](docs/ci.md) and `scripts/bootstrap_goose.py`).
2. Run documentation checks and the complete suite with `python3 manage.py ci`; set `GOOSE` and `CC` to select toolchains.
3. Build the example with `goose build examples/basic/server.goose -o build/server`.
4. Report the Goose revision, OS, C compiler and complete error output.

## Releases and docs

Versions follow [docs/releasing.md](docs/releasing.md): bump `VERSION` and `web::VERSION` together, add a
`CHANGELOG.md` entry, and tag `vX.Y.Z` on `main`. The documentation site is in `docs/site`; `pages.yml` publishes it
on each push to `main`, so keep its pages in step with `docs/api.md`.

## PR expectations

Describe behavior, safety implications, added tests and performance impact. Never describe a prototype as production hardened. Keep public API additive unless a breaking change is documented.

## Documentation

Start at [the documentation index](docs/README.md). Add task-oriented walkthroughs under
`docs/guide`, keep the exact API contract in `docs/api.md`, and link to runnable examples.
State whether a snippet is a complete program or a fragment. Verify commands with the pinned
compiler and distinguish current main from published tags. `python3 manage.py docs` checks local
Markdown links/fragments without network requests; see [documentation conventions](docs/documentation.md).
