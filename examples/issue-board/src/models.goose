import goose_web;
namespace issue_board;

struct Project { id: i64, name: u8[..120], description: u8[..500] }
struct ProjectInput { name: u8[..120] = "", description: u8[..500] = "" }
struct ProjectPatch { name: u8[..120] = "", description: u8[..500] = "" }
struct Issue { id: i64, project_id: i64, title: u8[..200], status: u8[..16] }
struct IssueInput { project_id: i64, title: u8[..200] = "", status: u8[..16] = "open" }
struct IssuePatch { title: u8[..200] = "", status: u8[..16] = "" }
struct BoardSettings { db_file: u8[..4096] = "build/issue-board.db", title: u8[..120] = "Issue Board API" }
fn status_valid(value: const u8[:]) -> bool { return value == "open" || value == "in_progress" || value == "closed"; }

fn web::db_table(v: issue_board::Project&) -> const u8[:] { "projects" }
fn web::db_table(v: issue_board::Issue&) -> const u8[:] { "issues" }
fn web::json_put_value(out: u8[>..]&, v: issue_board::Project&) -> bool { return web::json_put_fields(out, v); }
fn web::json_read_value(d: web::JsonDecoder&, out: issue_board::Project&) { web::json_read_fields(d, out); }
fn web::json_schema_value(out: u8[>..]&, v: issue_board::Project&) { web::json_schema_fields(out, v); }
fn web::json_put_value(out: u8[>..]&, v: issue_board::Issue&) -> bool { return web::json_put_fields(out, v); }
fn web::json_read_value(d: web::JsonDecoder&, out: issue_board::Issue&) { web::json_read_fields(d, out); }
fn web::json_schema_value(out: u8[>..]&, v: issue_board::Issue&) { web::json_schema_fields(out, v); }

fn web::rules(v: issue_board::ProjectInput&, r: web::Rules&) { r.field("name").required().min_len(1).max_len(120); }
fn web::rules(v: issue_board::ProjectPatch&, r: web::Rules&) { r.field("name").min_len(1).max_len(120); }
fn web::rules(v: issue_board::IssueInput&, r: web::Rules&) {
    r.field("project_id").required().ge(1);
    r.field("title").required().min_len(1).max_len(200);
}
fn web::rules(v: issue_board::IssuePatch&, r: web::Rules&) {
    r.field("title").min_len(1).max_len(200);
}
fn web::rules(v: issue_board::BoardSettings&, r: web::Rules&) {
    r.field("db_file").min_len(1).max_len(4096);
    r.field("title").min_len(1).max_len(120);
}
fn web::optional_fields(v: issue_board::ProjectInput&) -> const u8[:] { return "description"; }
fn web::optional_fields(v: issue_board::ProjectPatch&) -> const u8[:] { return "name,description"; }
fn web::optional_fields(v: issue_board::IssueInput&) -> const u8[:] { return "status"; }
fn web::optional_fields(v: issue_board::IssuePatch&) -> const u8[:] { return "title,status"; }
