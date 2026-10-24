#!/usr/bin/env python3
"""Check repository Markdown links and local fragments without network access."""
from pathlib import Path
from urllib.parse import unquote, urlsplit
import argparse
import os
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
IGNORED = {".git", ".claude", ".remember", "build", "__pycache__", "node_modules", ".venv"}
LINK = re.compile(r"\[[^\]\n]*\]\((<[^>\n]+>|[^\s)]+)(?:\s+\"[^\"]*\")?\)")
REFERENCE = re.compile(r"^\s*\[[^\]]+\]:\s*(\S+)", re.MULTILINE)


def prose(text):
    lines = []
    fence = None
    for line in text.splitlines():
        marker = re.match(r"^\s*(`{3,}|~{3,})", line)
        if marker:
            token = marker.group(1)
            if fence is None:
                fence = token
            elif token[0] == fence[0] and len(token) >= len(fence):
                fence = None
            lines.append("")
        else:
            lines.append(line if fence is None else "")
    return "\n".join(lines)


def anchors(path):
    text = prose(path.read_text(encoding="utf-8"))
    found = set(re.findall(r'\bid=["\']([^"\']+)["\']', text))
    counts = {}
    for heading in re.findall(r"^ {0,3}#{1,6}\s+(.+?)\s*#*\s*$", text, re.MULTILINE):
        heading = re.sub(r"<[^>]+>", "", heading).lower()
        slug = re.sub(r"[^\w\- ]", "", heading).replace(" ", "-")
        count = counts.get(slug, 0)
        counts[slug] = count + 1
        found.add(slug if count == 0 else f"{slug}-{count}")
    return found


def markdown_files(root):
    for directory, folders, files in os.walk(root):
        folders[:] = [name for name in folders if name not in IGNORED]
        for name in files:
            if name.endswith(".md"):
                yield Path(directory) / name


def check(root):
    errors = []
    checked = 0
    cache = {}
    for source in sorted(markdown_files(root)):
        text = prose(source.read_text(encoding="utf-8"))
        matches = sorted([*LINK.finditer(text), *REFERENCE.finditer(text)], key=lambda match: match.start())
        for match in matches:
            target = match.group(1).strip("<>")
            parsed = urlsplit(target)
            if parsed.scheme or parsed.netloc:
                continue
            checked += 1
            destination = source.parent / unquote(parsed.path) if parsed.path else source
            problem = None
            if not destination.exists():
                problem = "file does not exist"
            elif parsed.fragment and destination.is_file() and destination.suffix in (".md", ".html"):
                key = destination.resolve()
                if key not in cache:
                    cache[key] = anchors(destination)
                if unquote(parsed.fragment) not in cache[key]:
                    problem = "fragment does not exist"
            if problem:
                line = text.count("\n", 0, match.start()) + 1
                errors.append(f"{source.relative_to(root)}:{line}: {target}: {problem}")
    return checked, errors


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    args = parser.parse_args(argv)
    checked, errors = check(args.root.resolve())
    if errors:
        print("\n".join(errors), file=sys.stderr)
        print(f"Documentation: {len(errors)} broken links among {checked} local links", file=sys.stderr)
        return 1
    print(f"Documentation: {checked} local links and fragments checked (external URLs not fetched)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
