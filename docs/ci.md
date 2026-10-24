# Continuous integration

`.github/workflows/ci.yml` runs the `python3 manage.py ci` command (documentation links and the complete test suite) on
Ubuntu 24.04 with GCC and Clang. Both `CC` (native transport tests) and
`GOOSE_CC` (Goose-generated programs) select the matrix compiler. The Goose
compiler itself is built using a C++20 compiler (`g++` in CI).

## Compiler pin

The bootstrap script builds upstream Goose commit
[`6ad201219c80b2b8c7cf865cf7bcc01469e1ec5c`](https://github.com/aardappel/goose/commit/6ad201219c80b2b8c7cf865cf7bcc01469e1ec5c).
Its runtime identifier is `4d3da949e563`, matching the original local installation.
The runtime identifier is a hash of embedded runtime text, **not a Git commit**;
it cannot uniquely identify all compiler code. CI pins the full source revision
and checks the emitted runtime identifier after building.

The source tree includes TinyCC. The script sets `GOOSE_BUILTIN_LIBS` to an empty
string, which builds the compiler without optional graphics/audio/UI/physics
packages or their additional downloads. This follows the upstream
[build instructions](https://github.com/aardappel/goose/blob/6ad201219c80b2b8c7cf865cf7bcc01469e1ec5c/README.md#build-and-run)
and [CMake configuration](https://github.com/aardappel/goose/blob/6ad201219c80b2b8c7cf865cf7bcc01469e1ec5c/CMakeLists.txt).

The official checkout action is pinned to its
[v4.2.2 commit](https://github.com/actions/checkout/commit/11bd71901bbe5b1630ceea73d27597364c9af683).
The workflow uses read-only repository permissions and does not retain checkout
credentials. Each matrix job has a 20-minute deadline. No compiler cache is shared
between revisions or C compilers. Ubuntu runner packages can update; the source
compiler pin does not claim a bit-for-bit reproducible operating-system image.

## Run locally on Linux

Install Git, Python 3.9+, CMake 3.27+, a C++20 compiler, and GCC or Clang with C
library development headers. From the repository root:

```sh
python3 scripts/bootstrap_goose.py
export GOOSE="$PWD/build/tools/goose/build/goose"
export GOOSE_STDLIB="$PWD/build/tools/goose/source/stdlib"
CC=gcc GOOSE_CC=gcc python3 manage.py ci
CC=clang GOOSE_CC=clang python3 manage.py ci
```

The script downloads the fixed revision into `build/tools/goose/source`, builds
in `build/tools/goose/build`, verifies the emitted runtime, and compiles/runs a
small program importing `std`. Keep that source tree and set `GOOSE_STDLIB` as
shown: the out-of-tree executable does not automatically locate the sibling
source standard library. CI sets this environment variable explicitly.
`--destination /absolute/path` selects another location; `--jobs 2` controls build
parallelism. A matching clean source tree is reused; another revision or local
changes cause an explicit error rather than being overwritten.

To upgrade Goose, update both constants in `scripts/bootstrap_goose.py`, inspect
upstream changes, build in a fresh destination, and run both compiler variants.
Update this document with the new source revision and runtime identifier. GitHub
Actions results are available only after the workflow is pushed and executed.

## Application CI commands

`python3 manage.py ci` is the shared command for local checks and the GitHub workflow. `make ci`
is an optional alias. In the framework it checks local Markdown files/anchors and runs the suite;
in generated apps it typechecks the entry point and runs `test.py`. Child failures stop the
command and preserve a nonzero exit status. Neither command installs tools or deploys a service.
See [project tooling](guide/project-tooling.md) and [testing](guide/testing.md).
