# Getting started

This guide builds a small Goose Web application with a health check and a JSON endpoint. The
examples target the current checkout. Goose Web `v0.6.0` is the published release; features added
on `main` after that tag are not available to a program importing `aurthurm/goose-web@v0.6.0`.
Use a local checkout when following newer examples.

## Prerequisites

You need the Goose compiler, Git, and a C compiler (`cc`, `gcc`, or `clang`). The framework package
compiles native code on first fetch/build.

For a compiler version matching this repository's CI, build the pinned upstream Goose source:

```sh
python3 scripts/bootstrap_goose.py
export GOOSE="$PWD/build/tools/goose/build/goose"
export GOOSE_STDLIB="$PWD/build/tools/goose/source/stdlib"
export GOOSE_HOME="$PWD/build/cache"
```

The bootstrap pins Goose commit `6ad201219c80b2b8c7cf865cf7bcc01469e1ec5c`. If you already have a
compatible `goose` executable on `PATH`, you can use it instead with `export GOOSE=goose`. Both
build commands below invoke `"$GOOSE"` consistently. See [compiler setup](../ci.md).

## Choose a package source

For an application using the published release, import the versioned tag:

```goose
import goose_web from "aurthurm/goose-web@v0.6.0";
```

To follow APIs from this checkout, point at its local path. For example, from an application
directory next to the checkout:

```goose
import goose_web from "../goose-web";
```

Only the program's root source file declares the package import. The `v0.6.0` tag was checked as a
fetchable, buildable package; consult its release documentation if you must stay on that version.
Do not assume features documented for current `main` exist in the tag.

## Build the first app

Save this as `server.goose` beside your project source. It defines one app function, registers two
routes, and starts the server on loopback port 8080.

```goose
import goose_web from "../goose-web";
import std;

struct Health { status: u8[..8] }
struct Greeting { message: u8[..64] }

fn app(c: web::Ctx&) {
    c.routes() {
        c.get("/health") { c.json(Health { status: "ok" }); };
        c.get("/hello/:name") {
            let name = c.param("name");
            guard name.len <= 56 else {
                c.fail(web::HTTP_UNPROCESSABLE_CONTENT, "name_too_long", "Name must be at most 56 bytes");
                return;
            }
            c.json(Greeting { message: str("Hello, ", name) });
        };
    };
}

fn main() {
    var config = web::server_config();
    config.port = 8080;
    let started = web::run(config) { c => app(c) };
    if !started { abort("server failed"); }
}
```

Struct field capacities are byte limits. The path name is checked before constructing the fixed-size
greeting. See the [hello example](../../examples/hello/server.goose) for the same pattern.

Build and start it:

```sh
"$GOOSE" build server.goose -o build/server
./build/server
```

Try the routes in another terminal:

```sh
curl http://127.0.0.1:8080/health
curl http://127.0.0.1:8080/hello/Goose
```

The response is JSON. `c.routes()` returns 404 when no path matches and 405 with `Allow` when a
path matches but its method does not. Stop the server with Ctrl+C.

For a fuller starter layout, request-body example, generated OpenAPI docs, and a test script, see
the [starter project](../../templates/starter/README.md). For request and response details see
[Requests and responses](requests-and-responses.md), and the [application API reference](../api.md#application-api).
