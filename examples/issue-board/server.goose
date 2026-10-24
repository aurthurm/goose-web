import goose_web from "../..";
import goose_web_db from "../../db";
import issue_board from ".";
import os;

var board_settings = default<issue_board::BoardSettings>();
var control = default<web::ServerControl>();

fn app(c: web::Ctx&) {
    request_id(c) { c.logger() { c.secure_headers("default-src 'self'; script-src 'self' https://cdn.jsdelivr.net 'unsafe-inline'; style-src 'self' https://cdn.jsdelivr.net 'unsafe-inline'; font-src https://cdn.jsdelivr.net data:; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'", "") {
        web::openapi(c, web::OpenApiInfo { title: board_settings.title, version: "1.0.0",
            description: "Projects and issues persisted in SQLite." }) {
            c.routes() { issue_board::mount(c); };
        };
    }}};
}

fn lifecycle(stage: i32, stats: web::ServerStats) {
    if stage == web::SERVER_STOPPED { issue_board::close(); }
}

fn main() {
    let config, ok, error = web::config_from_args(args());
    if !ok { abort(error); }
    let rules_ok, rules_problem = web::check_rules<issue_board::BoardSettings>();
    if !rules_ok { abort(rules_problem); }
    let loaded, problems = web::settings<issue_board::BoardSettings>("BOARD_");
    if problems.items.len > 0 { abort("invalid BOARD_ settings"); }
    board_settings = loaded;
    issue_board::setup(board_settings.db_file[..]);
    config.handle_signals = true;
    print("Issue Board API listening on http://127.0.0.1:", config.port);
    let started = web::run_with(config, control, app, web::run_tick, lifecycle);
    issue_board::close();
    if !started { abort("server failed"); }
}
