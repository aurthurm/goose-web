# Issue Board API

A modular SQLite API for projects and issues. `server.goose` is the only executable entry point. It imports the `issue_board` package facade, which loads the model, store, and route modules.

## Build and run

From the repository root, use the task runner or the compiler directly:

```sh
python3 manage.py build --entry examples/issue-board/server.goose --output build/issue-board
python3 manage.py run --entry examples/issue-board/server.goose --output build/issue-board -- --port 8080
# Or run an already-built binary:
./build/issue-board --port 8080
```

The default port is 8080 and the default database file is `build/issue-board.db`; its parent directory must exist. The executable accepts the standard `web::config_from_args(args())` options, including `--workers` and `GOOSE_WEB_WORKERS`.

Typed application settings load at startup. Unset or empty variables use defaults; invalid values fail startup.

| Environment variable | Default | Meaning |
| --- | --- | --- |
| `BOARD_DB_FILE` | `build/issue-board.db` | SQLite database path |
| `BOARD_TITLE` | `Issue Board API` | OpenAPI document title |

Server options such as `--port`, `--host`, `--max-clients`, `--max-requests`, and `--workers` use the standard command-line parser. Startup applies append-only `web::migrate` steps, then closes the initialization connection before worker processes start. Each worker lazily opens its own SQLite connection on its first request, enables foreign key enforcement on that connection, and closes it during the stopped lifecycle callback. SQLite calls block the reactor thread for their duration, so this example suits small workloads with short queries.

## API

| Method and path | Result |
| --- | --- |
| `GET /projects` | List the first 100 projects by ID |
| `POST /projects` | Create a project; `name` is required |
| `GET /projects/:id` | Fetch one project |
| `PATCH /projects/:id` | Update a project name or description |
| `DELETE /projects/:id` | Delete a project and cascade to its issues |
| `GET /issues` | List the first 200 issues by ID |
| `POST /issues` | Create an issue under an existing project |
| `GET /issues/:id` | Fetch one issue |
| `PATCH /issues/:id` | Change title or status |
| `DELETE /issues/:id` | Delete an issue |
| `GET /openapi.json`, `GET /docs` | Generated OpenAPI document and Swagger UI |

Issue statuses are `open`, `in_progress`, and `closed`. Allowed transitions are `open` to `in_progress`, `in_progress` to `open` or `closed`, and `closed` to `open`; rejected transitions return 409. Request bodies use typed validation and responses include request IDs and security headers. The CSP permits the Swagger UI resources served from jsdelivr. This API does not implement authentication or authorization.

```sh
curl -i -H 'Content-Type: application/json' --data '{"name":"Platform","description":"Core services"}' http://127.0.0.1:8080/projects
curl -i -H 'Content-Type: application/json' --data '{"project_id":1,"title":"Add health checks"}' http://127.0.0.1:8080/issues
curl -X PATCH -H 'Content-Type: application/json' --data '{"status":"in_progress"}' http://127.0.0.1:8080/issues/1
curl http://127.0.0.1:8080/openapi.json
```

## Layout

```text
examples/issue-board/
├── server.goose                 # Process entry, config, settings, middleware, OpenAPI
├── issue_board.goose            # Package facade
└── src/
    ├── models.goose             # Records, settings, validation rules
    ├── store.goose              # SQLite lifecycle, migrations, errors
    └── routes.goose             # Handlers and route declarations
tests/integration/issue_board.py # Real-socket API and restart coverage
```

The integration test is run by `python3 tests/integration/issue_board.py build/issue-board` after building. It uses a temporary database, overrides `BOARD_DB_FILE` and `BOARD_TITLE`, exercises CRUD, transitions, validation, missing resources, cascade deletion, OpenAPI, and restart persistence.
