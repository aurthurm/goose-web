# Contributing

Goose Web is early-stage. File an issue before proposing new large APIs. Small fixes, compiler-compatibility reports and tests are welcome.

## Local development

1. Install a current compiler from [aardappel/goose](https://github.com/aardappel/goose/releases).
2. Use `goose check web.goose` and `goose check tests/router_test.goose` where supported.
3. On Linux/macOS, use `goose build examples/hello.goose` for the transport experiment.
4. Run the route test and HTTP smoke scripts after the compiler compatibility baseline is established.
5. Report the Goose revision, OS, C compiler and complete error output.

## PR expectations

Describe behavior, safety implications, added tests and performance impact. Never describe a prototype as production hardened. Keep public API additive unless a breaking change is documented.
