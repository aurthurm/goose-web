# Application settings

**Version:** `web::settings` and field rules are on `main` and are not in the published `v0.6.0`
package. This is a complete `main` startup example; replace the local package import if your
application is elsewhere.

Load application settings once in `main`, validate them, then pass or retain the resulting
configuration before the server starts. `web::settings<T>(prefix)` reads scalar fields by their
declared names; it does not read JSON field aliases.

```goose
import goose_web from "../goose-web";
import std;
import os;

struct AppSettings { port: i32 = 8080, workers: i32 = 1, public_bind: bool = false, secret: u8[..128] = "" }
fn web::rules(v: AppSettings&, r: web::Rules&) {
    r.field("port").ge(1).le(65535);
    r.field("workers").ge(1).le(256);
    r.field("secret").required().min_len(32).secret();
}
fn app(c: web::Ctx&) {
    c.routes() { c.get("/health") { c.text("ok"); }; };
}

fn main() {
    let rules_ok, rules_error = web::check_rules<AppSettings>();
    if !rules_ok { abort(rules_error); }
    let settings, issues = web::settings<AppSettings>("APP_");
    if issues.items.len > 0 {
        for i in issues.items.len {
            print("setting ", issues.items[i].loc[..], ": ", issues.items[i].msg[..]);
        }
        abort("invalid APP_ settings");
    }
    var config = web::server_config();
    config.port = settings.port;
    config.workers = settings.workers;
    config.public_bind = settings.public_bind;
    config.handle_signals = true;
    if !web::validate_server_config(config) { abort("invalid server configuration"); }
    let started = web::run(config) { c => app(c) };
    if !started { abort("server failed"); }
}
```

For this type, names are `APP_PORT`, `APP_WORKERS`, `APP_PUBLIC_BIND`, and `APP_SECRET`. For
secrets, set `APP_SECRET_FILE=/run/secrets/app-secret` to read the value from a file (maximum
4096 bytes); one trailing LF or CRLF is removed. Setting a nonempty direct value and its `_FILE`
path together is an error. Empty or unset variables retain defaults, but `.required()` still
requires an explicit secret. Defaults are validated too.

Always inspect `issues` before using the result: parse errors leave the field at its default,
whereas constraint errors leave the parsed value in place. `.secret()` redacts that field's
diagnostics. Boolean values also accept `yes`/`on` and `no`/`off`. `json_skip` excludes a field.

Keep this type scalar and bounded. Load once, not from a request handler. Save the complete
program as `server.goose` in a project beside the checkout and use the compiler configured in
[getting started](getting-started.md):

```sh
mkdir -p build
"$GOOSE" build server.goose -o build/server
APP_SECRET="local-demo-secret-replace-before-deploying" ./build/server
```

The [starter source](../../templates/starter/server.goose) shows a different settings type for
its title and note limit, alongside template checks, middleware and routes. Generate it with
`python3 manage.py new settings-demo ../settings-demo`; raw template files contain placeholders
and cannot be compiled in place. For command-line server options, see
[runtime configuration](../api.md#command-line-and-environment-configuration).

Full contract: [Settings API](../api.md#settings) and [validation](../api.md#validation).
