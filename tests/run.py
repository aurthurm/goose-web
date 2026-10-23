#!/usr/bin/env python3
"""One entry point for debug builds, unit tests, native tests, and socket tests."""
from pathlib import Path
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "build"


def main():
    BUILD.mkdir(exist_ok=True)
    env = dict(os.environ)
    env.setdefault("GOOSE_HOME", str(BUILD / "cache"))
    compiler = os.environ.get("GOOSE", "goose")
    if not shutil.which(compiler):
        raise SystemExit("Set GOOSE to the installed Goose compiler executable")
    programs = [("core", "tests/unit/core.goose"), ("router", "tests/unit/router.goose"),
                ("application", "tests/unit/application.goose"), ("constants", "tests/unit/constants.goose"),
                ("http_parser", "tests/unit/http_parser.goose"),
                ("json_codec", "tests/unit/json_codec.goose"),
                ("todo_store", "tests/unit/todo_store.goose"), ("todo_input", "tests/unit/todo_input.goose"),
                ("todo_api", "tests/unit/todo_api.goose"),
                ("parser_fuzz", "tests/fuzz/parser.goose"), ("features", "tests/fixtures/features.goose"),
                ("server", "examples/basic/server.goose")]
    for name, source in programs:
        subprocess.run([compiler, "build", str(ROOT / source), "--debug", "-o", str(BUILD / name)],
                       env=env, check=True, cwd=ROOT)
    for name in ("core", "router", "application", "constants", "http_parser", "json_codec", "todo_input", "todo_api", "parser_fuzz"):
        subprocess.run([str(BUILD / name)], check=True, timeout=60)
    with tempfile.TemporaryDirectory(prefix="goose-todo-unit-") as directory:
        subprocess.run([str(BUILD / "todo_store"), str(Path(directory) / "todos.json")], check=True, timeout=60)
    cc = os.environ.get("CC", "cc")
    subprocess.run([cc, "-std=c11", "-Wall", "-Wextra", "-Werror", str(ROOT / "tests/native/transport.c"),
                    "-o", str(BUILD / "transport")], check=True)
    subprocess.run([str(BUILD / "transport")], check=True)
    subprocess.run([sys.executable, str(ROOT / "tests/integration/http.py"), str(BUILD / "features")], env=env, check=True)
    subprocess.run([sys.executable, str(ROOT / "tests/integration/todos.py"), str(BUILD / "server")], env=env, check=True)
    subprocess.run([sys.executable, str(ROOT / "tests/integration/runtime.py")], env=env, check=True)


if __name__ == "__main__":
    main()
