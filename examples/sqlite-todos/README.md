# SQLite Todo example

A compact Todo API whose rows live in a SQLite file, built on the application DSL, `body<T>`,
`c.json` / `c.json_list`, and `web::db`. It is the persisted counterpart of `examples/basic`.

```sh
goose build examples/sqlite-todos/server.goose -o build/sqlite-todos
./build/sqlite-todos 8080 build/sqlite-todos.db    # port and file are optional
```

Requires `sqlite3.h` and `libsqlite3` (`libsqlite3-dev` on Debian and Ubuntu).

```sh
curl -i -H 'Content-Type: application/json' --data '{"title":"Write the layer"}' http://127.0.0.1:8080/todos
curl http://127.0.0.1:8080/todos
curl -X PATCH -H 'Content-Type: application/json' --data '{"done":true}' http://127.0.0.1:8080/todos/1
curl -i -X DELETE http://127.0.0.1:8080/todos/1
curl http://127.0.0.1:8080/openapi.json    # the OpenAPI 3.1 document; /docs has Swagger UI
```

The JSON key for the `completed` field is `done`. The SQL column keeps the name `completed`: the
renaming is a JSON concern only (`web::json_key`), so `"completed"` in a request is an unknown key (422).

| Method and path | Result |
| --- | --- |
| `GET /todos` | the first 100 todos by id, as a JSON array |
| `POST /todos` | 201 with the stored todo; empty title is 422 |
| `GET /todos/:id` | the todo, or 404 `todo_not_found` |
| `PATCH /todos/:id` | only the keys present in the body change |
| `DELETE /todos/:id` | 204, or 404 |
| `GET /openapi.json`, `GET /docs` | generated from the routes; schemas use `done` |

Restart the server with the same file and the todos are still there; ids continue from the largest
stored id. The file is opened in WAL mode. Every database call blocks the reactor thread for its
duration, which is fine for small rows and short statements.

The mapping is in `server.goose`: one struct, one `db_table` registration, and the codec registration
for the array element. The three `web::json_key` overloads (Todo, TodoInput, TodoPatch) rename `completed`
to `done`, and each route carries its OpenAPI annotations (`summary`, `accepts`, `returns`, `returns_list`,
`returns_empty`). Persistence, renaming and the document are checked in `tests/integration/sqlite_todos.py`.
