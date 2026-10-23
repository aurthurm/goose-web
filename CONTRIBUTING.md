# Contributing

Goose Web is early-stage. File an issue before proposing new large APIs. Small fixes, compiler-compatibility reports and tests are welcome.

## Local development

1. Install the pinned upstream compiler from [aardappel/goose](https://github.com/aardappel/goose) (see [docs/ci.md](docs/ci.md) and `scripts/bootstrap_goose.py`).
2. Run the complete suite with `python3 tests/run.py`; set `GOOSE` and `CC` to select toolchains.
3. Build the example with `goose build examples/basic/server.goose -o build/server`.
4. Report the Goose revision, OS, C compiler and complete error output.

## PR expectations

Describe behavior, safety implications, added tests and performance impact. Never describe a prototype as production hardened. Keep public API additive unless a breaking change is documented.
