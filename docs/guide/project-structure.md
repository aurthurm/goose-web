# One entry point, multiple modules

A Goose Web application builds from one root `.goose` file. That root declares external package
sources; imported modules share those declarations and import packages by name. Adding more
source files does not create more executables or more servers.

## Follow the Issue Board layout

The runnable [Issue Board](../../examples/issue-board/README.md) uses this structure:

```text
examples/issue-board/
  server.goose             executable entry: imports, settings, startup, middleware
  issue_board.goose        package facade: imports application modules
  src/
    models.goose           records, field rules, JSON/SQL registrations
    store.goose            database connection, migrations and storage errors
    routes.goose           resource handlers and route declarations
```

`server.goose` declares the packages, then starts the server once. These are its package imports:

```goose
import goose_web from "../..";
import goose_web_db from "../../db";
import issue_board from ".";
```

`issue_board` is an application-local package. Its directory contains `issue_board.goose`, the
facade that imports the modules:

```goose
import .src.models;
import .src.store;
import .src.routes;
```

Modules use `namespace issue_board;` for their exported functions and import sibling modules
with relative module imports such as `import .models;`. They use `import goose_web;` rather than
redeclarating its source. Keep package sources in the executable entry so the entire program
uses one version of each dependency.

## Mount routes from modules

A resource module can expose `mount(c: web::Ctx&)`; the entry calls it inside the app's routes
block. This is a partial composition pattern, using the example package's existing `mount`:

```goose
fn app(c: web::Ctx&) {
    request_id(c) {
        c.routes() { issue_board::mount(c); };
    };
}
```

The framework evaluates route declarations for matching and dispatch (and for OpenAPI
when enabled). Put database writes and other effects inside handler bodies, not in `mount`
outside those bodies. A module may declare groups, annotations and routes, but should not start
a second server as a side effect of being imported.

As the application grows, split `routes.goose` by resource and put domain decisions in a service
module. For example, the Issue Board validates request fields before applying its status-transition
policy; an invalid transition is a business conflict (409), distinct from a malformed payload.
Avoid making every module aware of the request context when it only needs domain values.

## Own state and resources explicitly

- Load typed configuration during startup, validate it, then keep it available to handlers.
- A global belongs to one worker process. Use a namespace to make its ownership clear; it is not
  shared between pre-fork workers.
- Apply database migrations before serving. Close that startup handle before forking; open a
  separate connection in each worker. See [database lifecycle](database.md).
- Stop job pools and close per-process resources during the server lifecycle. Do not hold a
  mutable request context or its borrowed fields after a handler returns.

See the source of [server.goose](../../examples/issue-board/server.goose),
[the facade](../../examples/issue-board/issue_board.goose) and
[the model module](../../examples/issue-board/src/models.goose) for concrete implementations.

## Build and test the entire application

From the framework checkout:

```sh
python3 manage.py check --entry examples/issue-board/server.goose
python3 manage.py build --entry examples/issue-board/server.goose --output build/issue-board
python3 tests/integration/issue_board.py build/issue-board
```

The entry file's imports bring in every module. The test starts the executable on a free port,
exercises its resources, then restarts it against the same database to verify persistence.
The framework suite includes it when SQLite development files are available.
For command conventions in your own project, see [project tooling](project-tooling.md).
