# Testing Goose Web applications

Start with a compiler and native toolchain that match the app's Goose Web source. The framework's
own test suite targets this checkout; the published `v0.6.0` package does not include later `main`
features exercised by current tests.

Set `GOOSE` to the compiler executable and use an absolute cache path. If you built the pinned
compiler with `scripts/bootstrap_goose.py`, also set `GOOSE_STDLIB` as shown in
[compiler setup](../ci.md):

```sh
export GOOSE="/absolute/path/to/goose"
export GOOSE_HOME="$PWD/build/cache"
# For the repository bootstrap build only:
export GOOSE_STDLIB="$PWD/build/tools/goose/source/stdlib"
```

`manage.py` also normalizes `GOOSE_HOME` to an absolute path. It uses `goose` from `PATH` when
`GOOSE` is unset. Python commands use only the standard library; compiling framework packages
still needs Git and a C compiler.

## Check and build an application

The repository's `manage.py` wraps common commands and selects `examples/hello/server.goose` as
the default entry when the checkout itself has no `server.goose`:

```sh
python3 manage.py check --entry examples/hello/server.goose
python3 manage.py build --entry examples/hello/server.goose --output build/hello
./build/hello 8080
```

You can use the Makefile equivalents:

```sh
make check ENTRY=examples/hello/server.goose
make build ENTRY=examples/hello/server.goose OUTPUT=build/hello
make run ENTRY=examples/hello/server.goose ARGS="8080"
```

`check` typechecks the entry point; `build` compiles it. `run` builds and forwards arguments after
`--` to the program. These checks catch compile-time mistakes but do not prove socket behavior.

## Exercise a real HTTP socket

The repository's `tests/integration/hello.py` uses Python's standard-library `socket` module to
start the built server, send HTTP/1.1 bytes, parse `Content-Length`, and check health, routing,
typed POST decoding, and error responses. Run it after building:

```sh
python3 tests/integration/hello.py build/hello
```

A minimal one-request probe can use the same framing idea:

```python
import socket

with socket.create_connection(("127.0.0.1", 8080), timeout=3) as client:
    client.sendall(b"GET /health HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
    response = bytearray()
    while b"\r\n\r\n" not in response:
        chunk = client.recv(4096)
        assert chunk, "connection closed before response headers"
        response.extend(chunk)
    headers, body = response.split(b"\r\n\r\n", 1)
    length = int(next(line.split(b":", 1)[1] for line in headers.split(b"\r\n")
                      if line.lower().startswith(b"content-length:")))
    while len(body) < length:
        chunk = client.recv(4096)
        assert chunk, "connection closed inside response body"
        body += chunk
    print(headers.split(b"\r\n", 1)[0].decode(), body[:length].decode())
```

Run the probe while the server is running. Real integration tests should use a temporary free port,
timeouts, and a `finally` block that stops the server, as the checked-in harness does.

## Run project checks

```sh
python3 manage.py test
python3 manage.py ci
python3 manage.py docs
```

Equivalent Make targets are `make test`, `make ci`, and `make docs`. `test` runs the complete suite;
`ci` checks repository Markdown links first and then runs that suite; `docs` checks links only. The
generated starter is built and exercised by its own test script, while link checking covers this
checkout's documentation. See
[manage.py](../../manage.py) and the [Makefile](../../Makefile) for command options.

The suite builds debug Goose programs and runs unit contracts, native C checks, and real socket
integration tests. It also builds a starter from this checkout, runs its standard-library test
script, and checks generated docs links under `ci`. Deterministic parser/JSON/input/template/static
fuzz-property checks run as part of the test suite. Native libFuzzer harnesses run for 10 seconds
each by default and are skipped if Clang lacks `-fsanitize=fuzzer,address`; the SQLite unit and
integration cases are skipped when SQLite headers or libraries are unavailable. Install
`libsqlite3-dev` on Debian/Ubuntu to include them. `GOOSE_FUZZ_SECONDS` changes the native fuzzer
duration. More detail is in [CI setup](../ci.md) and [tests/run.py](../../tests/run.py).
