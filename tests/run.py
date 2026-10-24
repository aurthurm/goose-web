#!/usr/bin/env python3
"""One entry point for debug builds, unit tests, native tests, and socket tests."""
from pathlib import Path
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "build"


def sqlite_available(cc):
    """The SQLite layer needs sqlite3.h and libsqlite3 (libsqlite3-dev). Probe by building a program."""
    probe = "#include <sqlite3.h>\nint main(void) { return sqlite3_libversion_number() > 0 ? 0 : 1; }\n"
    with tempfile.TemporaryDirectory(prefix="goose-sqlite-probe-") as directory:
        source = Path(directory) / "probe.c"
        source.write_text(probe)
        result = subprocess.run([cc, str(source), "-lsqlite3", "-o", str(Path(directory) / "probe")],
                                capture_output=True)
        return result.returncode == 0


def check_version():
    """The VERSION file and web::VERSION in src/constants/runtime.goose must name the same release."""
    version = (ROOT / "VERSION").read_text().strip()
    declared = re.search(r'^const VERSION = "([^"]+)";$',
                         (ROOT / "src/constants/runtime.goose").read_text(), re.MULTILINE)
    if not declared or declared.group(1) != version:
        raise SystemExit(f"VERSION file says {version!r}; src/constants/runtime.goose must declare the same")
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise SystemExit(f"VERSION must be MAJOR.MINOR.PATCH, not {version!r}")


def main():
    BUILD.mkdir(exist_ok=True)
    check_version()
    env = dict(os.environ)
    env.setdefault("GOOSE_HOME", str(BUILD / "cache"))
    compiler = os.environ.get("GOOSE", "goose")
    if not shutil.which(compiler):
        raise SystemExit("Set GOOSE to the installed Goose compiler executable")
    cc = os.environ.get("CC", "cc")
    with_sqlite = sqlite_available(cc)
    if not with_sqlite:
        print("SKIP: sqlite3.h or libsqlite3 not found; skipping the web::db unit test and the "
              "sqlite-todos example (install libsqlite3-dev to run them)", flush=True)
    programs = [("core", "tests/unit/core.goose"), ("router", "tests/unit/router.goose"),
                ("application", "tests/unit/application.goose"), ("constants", "tests/unit/constants.goose"),
                ("http_parser", "tests/unit/http_parser.goose"),
                ("app_routes", "tests/unit/app_routes.goose"), ("app_security", "tests/unit/app_security.goose"),
                ("json_codec", "tests/unit/json_codec.goose"),
                ("app_middleware", "tests/unit/app_middleware.goose"),
                ("app_params", "tests/unit/app_params.goose"),
                ("todo_store", "tests/unit/todo_store.goose"), ("todo_query", "tests/unit/todo_query.goose"),
                ("todo_api", "tests/unit/todo_api.goose"),
                ("app_config", "tests/unit/app_config.goose"), ("static_files", "tests/unit/static_files.goose"),
                ("global_names", "tests/unit/global_names.goose"),
                ("app_openapi", "tests/unit/app_openapi.goose"), ("sse", "tests/unit/sse.goose"),
                ("app_templates", "tests/unit/app_templates.goose"),
                ("sessions", "tests/unit/sessions.goose"), ("csrf", "tests/unit/csrf.goose"),
                ("live_reload", "tests/unit/live_reload.goose"),
                ("parser_fuzz", "tests/fuzz/parser.goose"), ("features", "tests/fixtures/features.goose"),
                ("app", "tests/fixtures/app.goose"), ("routing", "tests/fixtures/routing.goose"),
                ("hello", "examples/hello/server.goose"),
                ("pages", "examples/pages/server.goose"), ("server", "examples/basic/server.goose"),
                ("sse_fixture", "tests/fixtures/sse.goose"), ("sse_clock", "examples/sse-clock/server.goose"),
                ("workers", "tests/fixtures/workers.goose"), ("stats_record", "tests/unit/stats_record.goose")]
    if with_sqlite:
        programs += [("db", "tests/unit/db.goose"), ("sqlite_todos", "examples/sqlite-todos/server.goose")]
    for name, source in programs:
        subprocess.run([compiler, "build", str(ROOT / source), "--debug", "-o", str(BUILD / name)],
                       env=env, check=True, cwd=ROOT)
    for name in ("core", "router", "application", "app_routes", "app_security", "app_middleware", "app_params", "constants",
                 "http_parser", "json_codec", "todo_query", "todo_api", "app_openapi", "app_templates", "parser_fuzz",
                 "app_config", "global_names", "sse", "sessions", "csrf", "live_reload", "stats_record") + (("db",) if with_sqlite else ()):
        # Run from the repository root: the static file checks use tests/fixtures/static.
        subprocess.run([str(BUILD / name)], check=True, timeout=60, cwd=ROOT)
    with tempfile.TemporaryDirectory(prefix="goose-todo-unit-") as directory:
        subprocess.run([str(BUILD / "todo_store"), str(Path(directory) / "todos.json")], check=True, timeout=60)
    with tempfile.TemporaryDirectory(prefix="goose-static-unit-") as directory:
        subprocess.run([str(BUILD / "static_files"), directory], check=True, timeout=60)
    # The reactor has two backends (epoll on Linux, poll elsewhere); both run the same native checks.
    for name, flags in (("transport", []), ("transport_poll", ["-DGW_REACTOR_POLL"])):
        subprocess.run([cc, "-std=c11", "-Wall", "-Wextra", "-Werror", *flags, str(ROOT / "tests/native/transport.c"),
                        "-o", str(BUILD / name)], check=True)
        subprocess.run([str(BUILD / name)], check=True)
    subprocess.run([cc, "-std=c11", "-Wall", "-Wextra", "-Werror", str(ROOT / "tests/native/system.c"),
                    "-o", str(BUILD / "system")], check=True)
    subprocess.run([str(BUILD / "system")], check=True)
    subprocess.run([cc, "-std=c11", "-Wall", "-Wextra", "-Werror", str(ROOT / "tests/native/crypto.c"),
                    "-o", str(BUILD / "crypto")], check=True)
    subprocess.run([str(BUILD / "crypto")], check=True)
    subprocess.run([cc, "-std=c11", "-Wall", "-Wextra", "-Werror", str(ROOT / "tests/native/process.c"),
                    "-o", str(BUILD / "process")], check=True)
    subprocess.run([str(BUILD / "process")], check=True)
    subprocess.run([sys.executable, str(ROOT / "tests/integration/http.py"), str(BUILD / "features")], env=env, check=True)
    subprocess.run([sys.executable, str(ROOT / "tests/integration/app.py"), str(BUILD / "app")], env=env, check=True)
    subprocess.run([sys.executable, str(ROOT / "tests/integration/routing.py"), str(BUILD / "routing")], env=env, check=True)
    subprocess.run([sys.executable, str(ROOT / "tests/integration/hello.py"), str(BUILD / "hello")], env=env, check=True)
    subprocess.run([sys.executable, str(ROOT / "tests/integration/pages.py"), str(BUILD / "pages")], env=env, check=True)
    subprocess.run([sys.executable, str(ROOT / "tests/integration/todos.py"), str(BUILD / "server")], env=env, check=True)
    subprocess.run([sys.executable, str(ROOT / "tests/integration/runtime.py")], env=env, check=True)
    subprocess.run([sys.executable, str(ROOT / "tests/integration/workers.py"), str(BUILD / "workers")],
                   env=env, check=True)
    # The development server: watcher, debounce and build-failure handling (fake build), then a real
    # rebuild-and-reload cycle through the goose compiler.
    subprocess.run([sys.executable, str(ROOT / "tests/unit/dev_watch_test.py")], env=env, check=True)
    subprocess.run([sys.executable, str(ROOT / "tests/integration/dev_reload_test.py")],
                   env=dict(env, GOOSE=compiler), check=True)
    subprocess.run([sys.executable, str(ROOT / "tests/integration/sse.py"), str(BUILD / "sse_fixture")],
                   env=env, check=True)
    if with_sqlite:
        subprocess.run([sys.executable, str(ROOT / "tests/integration/sqlite_todos.py"), str(BUILD / "sqlite_todos")],
                       env=env, check=True)
    # The starter a user copies: generate it against this checkout, then build and exercise it.
    starter_env = dict(env, GOOSE=compiler)
    with tempfile.TemporaryDirectory(prefix="goose-starter-") as directory:
        project = Path(directory) / "starter"
        subprocess.run([sys.executable, str(ROOT / "scripts/new_project.py"), "starter-check", str(project),
                        "--source", str(ROOT)], check=True, cwd=ROOT)
        subprocess.run([sys.executable, str(project / "test.py")], env=starter_env, check=True, cwd=project)


if __name__ == "__main__":
    main()
