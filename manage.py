#!/usr/bin/env python3
"""Goose Web project commands. Python standard library only; run --help for usage."""
from pathlib import Path
import argparse
import os
import subprocess
import sys

ROOT = Path(__file__).resolve().parent


def environment():
    env = dict(os.environ)
    # Absolute cache paths also work when a test builds a program in a temporary directory.
    env["GOOSE_HOME"] = str(Path(env.get("GOOSE_HOME", ROOT / "build/cache")).expanduser().resolve())
    return env


def run(command, env):
    print("+ " + " ".join(map(str, command)), flush=True)
    subprocess.run(list(map(str, command)), cwd=ROOT, env=env, check=True)


def parser():
    cli = argparse.ArgumentParser(description=__doc__)
    commands = cli.add_subparsers(dest="command", required=True)
    entry = "server.goose" if (ROOT / "server.goose").is_file() else "examples/hello/server.goose"
    for name in ("check", "fetch", "build", "run", "dev"):
        command = commands.add_parser(name, help={
            "check": "typecheck the entry point", "fetch": "fetch its declared dependencies",
            "build": "build an executable", "run": "build and run an executable",
            "dev": "watch, rebuild and reload during development",
        }[name])
        command.add_argument("--entry", default=entry, help="root .goose file, relative to this project")
        if name in ("build", "run"):
            command.add_argument("--output", default="build/server")
        if name in ("build", "run", "dev"):
            command.add_argument("--release", action="store_true", help="optimized build without --debug checks")
        if name == "dev":
            command.add_argument("--port", type=int, default=8080)
            command.add_argument("--reload-port", type=int)
            command.add_argument("--watch", action="append", default=[])
            command.add_argument("--polling", action="store_true")
        if name in ("run", "dev"):
            command.add_argument("args", nargs=argparse.REMAINDER, help="program arguments after --")
    commands.add_parser("test", help="run the project's test suite")
    commands.add_parser("ci", help="check documentation and run the test suite; fail on any error")
    commands.add_parser("toolchain", help="report compiler and native build tools")
    docs = commands.add_parser("docs", help="check documentation links or serve the static site")
    docs.add_argument("--serve", action="store_true")
    docs.add_argument("--port", type=int, default=8000)
    new = commands.add_parser("new", help="generate a starter from this framework checkout")
    new.add_argument("name")
    new.add_argument("directory", nargs="?")
    new.add_argument("--source", help="override the framework source (must match the template's APIs)")
    return cli


def main(argv=None):
    cli = parser()
    args = cli.parse_args(argv)
    env = environment()
    compiler = env.get("GOOSE", "goose")
    try:
        if args.command in ("check", "fetch", "build", "run", "dev"):
            entry = ROOT / args.entry
            if not entry.is_file():
                cli.error(f"entry point does not exist: {entry}")
            if args.command in ("check", "fetch"):
                run([compiler, args.command, entry], env)
            elif args.command == "dev":
                command = [sys.executable, ROOT / "scripts/dev.py", entry, "--goose", compiler,
                           "--port", args.port]
                if args.reload_port is not None:
                    command += ["--reload-port", args.reload_port]
                if args.release:
                    command.append("--release")
                if args.polling:
                    command.append("--polling")
                for directory in args.watch:
                    command += ["--watch", directory]
                command += args.args
                run(command, env)
            else:
                output = (ROOT / args.output).resolve()
                output.parent.mkdir(parents=True, exist_ok=True)
                command = [compiler, "build", entry, "-o", output]
                command += ["-O2"] if args.release else ["--debug"]
                run(command, env)
                if args.command == "run":
                    forwarded = args.args[1:] if args.args[:1] == ["--"] else args.args
                    run([output, *forwarded], env)
        elif args.command == "toolchain":
            run([compiler, "version"], env)
            run([compiler, "toolchain"], env)
        elif args.command in ("test", "ci"):
            checks = ROOT / "scripts/check_docs.py"
            if args.command == "ci" and checks.is_file():
                run([sys.executable, checks], env)
            suite = ROOT / "tests/run.py"
            if not suite.is_file():
                suite = ROOT / "test.py"
                run([compiler, "check", ROOT / "server.goose"], env)
            if not suite.is_file():
                cli.error("no tests/run.py or test.py found")
            run([sys.executable, suite], env)
        elif args.command == "new":
            generator = ROOT / "scripts/new_project.py"
            if not generator.is_file():
                cli.error("new is available in a Goose Web framework checkout; use this project's entry point to build it")
            command = [sys.executable, generator, args.name]
            if args.directory:
                command.append(args.directory)
            if args.source:
                command += ["--source", args.source]
            run(command, env)
        elif args.command == "docs":
            if args.serve:
                site = ROOT / "docs/site"
                if not site.is_dir():
                    cli.error("this project has no docs/site; read README.md and use the app's /docs route")
                run([sys.executable, "-m", "http.server", args.port, "--bind", "127.0.0.1",
                     "--directory", site], env)
            else:
                checks = ROOT / "scripts/check_docs.py"
                if not checks.is_file():
                    cli.error("documentation checks are available in the framework checkout")
                run([sys.executable, checks], env)
    except subprocess.CalledProcessError as error:
        return error.returncode if error.returncode > 0 else 1
    except FileNotFoundError as error:
        print(f"Missing tool: {error.filename}. Set GOOSE or install the required toolchain.", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        return 130
    return 0


if __name__ == "__main__":
    sys.exit(main())
