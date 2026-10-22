#!/usr/bin/env python3
"""Build the fixed Goose source revision used by Linux CI (no optional packages)."""
from pathlib import Path
import argparse
import os
import re
import subprocess

GOOSE_REPOSITORY = "https://github.com/aardappel/goose.git"
GOOSE_REVISION = "6ad201219c80b2b8c7cf865cf7bcc01469e1ec5c"
RUNTIME_VERSION = "4d3da949e563"


def run(*command):
    subprocess.run(command, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--destination", type=Path, default=Path("build/tools/goose"))
    parser.add_argument("--jobs", type=int, default=2)
    args = parser.parse_args()
    if args.jobs < 1:
        parser.error("--jobs must be positive")
    destination = args.destination.resolve()
    source = destination / "source"
    build = destination / "build"
    destination.mkdir(parents=True, exist_ok=True)
    if not source.exists():
        run("git", "init", str(source))
        run("git", "-C", str(source), "remote", "add", "origin", GOOSE_REPOSITORY)
        run("git", "-C", str(source), "fetch", "--depth=1", "origin", GOOSE_REVISION)
        run("git", "-C", str(source), "checkout", "--detach", GOOSE_REVISION)
    revision = subprocess.check_output(
        ["git", "-C", str(source), "rev-parse", "HEAD"], text=True
    ).strip()
    if revision != GOOSE_REVISION:
        raise SystemExit(f"Existing source has revision {revision}; use a fresh destination")
    if subprocess.check_output(["git", "-C", str(source), "status", "--porcelain"]):
        raise SystemExit("Existing compiler source is modified; use a fresh destination")
    run("cmake", "-S", str(source), "-B", str(build),
        "-DCMAKE_BUILD_TYPE=Release", "-DGOOSE_BUILTIN_LIBS=")
    run("cmake", "--build", str(build), "--config", "Release", "--parallel", str(args.jobs))
    compiler = build / "goose"
    runtime = destination / "runtime.c"
    run(str(compiler), "--emit-runtime", str(runtime))
    match = re.search(r"^#define GS_RUNTIME_VERSION (\w+)$", runtime.read_text(), re.MULTILINE)
    if not match or match.group(1) != RUNTIME_VERSION:
        raise SystemExit("Pinned compiler emitted an unexpected runtime identifier")
    # An out-of-tree build cannot find the sibling source standard library by
    # its executable path alone. Prove the documented environment is usable.
    smoke_source = destination / "smoke.goose"
    smoke_source.write_text('import std;\nfn main() { assert(1 + 1 == 2); }\n')
    smoke_program = destination / "smoke"
    smoke_env = dict(os.environ, GOOSE_STDLIB=str(source / "stdlib"),
                     GOOSE_HOME=str(destination / "smoke-cache"))
    subprocess.run([str(compiler), "build", str(smoke_source), "--debug", "-o", str(smoke_program)],
                   env=smoke_env, check=True)
    run(str(smoke_program))
    print(f"GOOSE_STDLIB={source / 'stdlib'}")
    print(f"Verified Goose {GOOSE_REVISION}; runtime {RUNTIME_VERSION}")
    print(compiler)


if __name__ == "__main__":
    main()
