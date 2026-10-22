# Goose Web

A lightweight, API-first HTTP framework for the [Goose programming language](https://github.com/aardappel/goose).

> **Status: experimental pre-alpha.** See [ROADMAP.md](ROADMAP.md) once the bootstrap PR is merged. The API is not stable and the first transport is deliberately synchronous.

Design principles: a tiny Goose-first core, explicit request ownership, small and auditable C socket shim, compile-time composability, secure HTTP defaults, and optional extensions.

Development takes place in reviewable pull requests. This repository targets the upstream Goose compiler, not Go or Rust.
