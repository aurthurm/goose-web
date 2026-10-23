// goose_web_db: opt-in reflective SQLite layer. Contract: docs/api.md, "SQLite (web::db)".
// Import it beside goose_web: import goose_web_db from "path/to/db";  The core framework
// does not link libsqlite3; this package's sidecar does.
import .sqlite;
import .query;
import .records;
