#!/usr/bin/env python3
"""Stands in for `goose build` in the dev.py tests: python3 fake_build.py SOURCE OUTPUT.

A source containing BROKEN fails with compiler-like output. Otherwise OUTPUT becomes an executable
that serves the source's first line as the body of every GET, on the port named by --port.
"""
import os
import stat
import sys

SERVER = '''#!{python}
import http.server
import sys

MESSAGE = {message!r}


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = (MESSAGE + "\\n").encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        pass


port = int(sys.argv[sys.argv.index("--port") + 1])
http.server.HTTPServer(("127.0.0.1", port), Handler).serve_forever()
'''


def main():
    source, output = sys.argv[1], sys.argv[2]
    with open(source, encoding="utf-8") as handle:
        text = handle.read()
    if "BROKEN" in text:
        print(f"{source}:1: error: fake compile failure")
        return 1
    message = text.splitlines()[0] if text.strip() else ""
    with open(output, "w", encoding="utf-8") as handle:
        handle.write(SERVER.format(python=sys.executable, message=message))
    os.chmod(output, os.stat(output).st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    return 0


if __name__ == "__main__":
    sys.exit(main())
