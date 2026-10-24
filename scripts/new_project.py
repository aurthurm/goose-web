#!/usr/bin/env python3
"""Create a Goose Web project from templates/starter.

Usage:
  python3 scripts/new_project.py NAME [DIR] [--source SOURCE]

NAME    project name: starts with a letter, then lowercase letters, digits, "-" or "_".
DIR     where to create it (default: ./NAME). It must not exist, or must be an empty directory.
--source
        where the program fetches goose_web from, written into its import line. Default: the
        GitHub tag matching this checkout's VERSION file, for example aurthurm/goose-web@v0.6.0.
        A local directory (the path to a goose-web checkout) also works; it is written relative
        to the new project, so the generated program builds in place.
"""
from pathlib import Path
import argparse
import os
import re
import shutil
import sys

ROOT = Path(__file__).resolve().parents[1]
TEMPLATE = ROOT / "templates" / "starter"
SOURCE_PLACEHOLDER = "GOOSE_WEB_SOURCE"
NAME_PLACEHOLDER = "PROJECT_NAME"
DEFAULT_REPOSITORY = "aurthurm/goose-web"
NAME_PATTERN = re.compile(r"[a-z][a-z0-9_-]*")
TEXT_SUFFIXES = {".goose", ".md", ".py", ".html", ".txt", ".build", ""}


def default_source():
    version = (ROOT / "VERSION").read_text().strip()
    return f"{DEFAULT_REPOSITORY}@v{version}"


def package_source(value, destination):
    """A local directory becomes a path relative to the new project; anything else is passed through."""
    local = Path(value).expanduser()
    if not local.is_absolute():
        candidate = (Path.cwd() / local)
        if candidate.is_dir():
            local = candidate
    if local.is_dir():
        relative = os.path.relpath(local.resolve(), destination.resolve())
        return Path(relative).as_posix()
    return value


def fill(text, replacements):
    for placeholder, value in replacements.items():
        text = text.replace(placeholder, value)
    return text


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("name")
    parser.add_argument("directory", nargs="?")
    parser.add_argument("--source", default=None)
    args = parser.parse_args()

    if not NAME_PATTERN.fullmatch(args.name):
        parser.error(f"invalid project name {args.name!r}: use lowercase letters, digits, '-' or '_', starting with a letter")
    destination = Path(args.directory or args.name).resolve()
    if destination.exists() and (not destination.is_dir() or any(destination.iterdir())):
        parser.error(f"{destination} exists and is not an empty directory")
    if not TEMPLATE.is_dir():
        parser.error(f"starter template missing at {TEMPLATE}")

    source = package_source(args.source or default_source(), destination)
    if '"' in source or "\n" in source:
        parser.error("the package source must not contain quotes or newlines")

    replacements = {SOURCE_PLACEHOLDER: source, NAME_PLACEHOLDER: args.name}
    shutil.copytree(TEMPLATE, destination, dirs_exist_ok=True,
                    ignore=shutil.ignore_patterns("__pycache__", "build"))
    for path in destination.rglob("*"):
        if path.is_file() and path.suffix in TEXT_SUFFIXES:
            text = path.read_text(encoding="utf-8")
            updated = fill(text, replacements)
            if updated != text:
                path.write_text(updated, encoding="utf-8")

    # The development server (rebuild and reload on change) is copied in, so the project runs without this checkout.
    (destination / "scripts").mkdir(exist_ok=True)
    shutil.copy2(ROOT / "scripts" / "dev.py", destination / "scripts" / "dev.py")

    print(f"created {destination}")
    print(f"import goose_web from \"{source}\";")
    print(f"next: cd {destination} && python3 test.py")


if __name__ == "__main__":
    sys.exit(main())
