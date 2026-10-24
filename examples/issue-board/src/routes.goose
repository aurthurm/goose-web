import goose_web;
import .models;
import .store;
namespace issue_board;

fn list_projects(c: web::Ctx&) {
    guard ready(c) else { return; }
    var rows: Project[..100] = [];
    let ok = web::select<Project>(database, web::limit(web::order_by(web::query(), "id", false), 100)) { row => rows.push(row); };
    if !ok { failed(c); return; }
    c.json_list(rows[..]);
}
fn create_project(c: web::Ctx&) {
    guard ready(c) else { return; }
    let input, ok = body<ProjectInput>(c); guard ok else { return; }
    var project = Project { id: 0, name: input.name, description: input.description };
    let id, inserted = web::insert(database, project);
    if !inserted { failed(c); return; }
    c.status(web::HTTP_CREATED).json(Project { id: id, name: input.name, description: input.description });
}
fn get_project(c: web::Ctx&) {
    guard ready(c) else { return; }
    let id, ok = c.param_int("id"); guard ok else { return; }
    let item, found = web::find_row<Project>(database, id);
    if !found { missing(c, "project"); return; } c.json(item);
}
fn patch_project(c: web::Ctx&) {
    guard ready(c) else { return; }
    let id, ok = c.param_int("id"); guard ok else { return; }
    var input, result = web::body_decode<ProjectPatch>(c);
    guard web::validate_result(c, "body", input, result) else { return; }
    let current, found = web::find_row<Project>(database, id);
    if !found { missing(c, "project"); return; }
    let has_name = web::has<ProjectPatch>(result, "name");
    let has_description = web::has<ProjectPatch>(result, "description");
    if !has_name && !has_description { c.fail(web::HTTP_UNPROCESSABLE_CONTENT, "invalid_payload", "Provide name or description"); return; }
    var updated = current;
    if has_name { updated.name = input.name; }
    if has_description { updated.description = input.description; }
    if !web::update(database, updated) { failed(c); return; } c.json(updated);
}
fn delete_project(c: web::Ctx&) {
    guard ready(c) else { return; }
    let id, ok = c.param_int("id"); guard ok else { return; }
    let _, found = web::find_row<Project>(database, id);
    if !found { missing(c, "project"); return; }
    if !web::remove<Project>(database, id) { failed(c); return; } c.no_content();
}
fn list_issues(c: web::Ctx&) {
    guard ready(c) else { return; }
    var rows: Issue[..200] = [];
    let ok = web::select<Issue>(database, web::limit(web::order_by(web::query(), "id", false), 200)) { row => rows.push(row); };
    if !ok { failed(c); return; }
    c.json_list(rows[..]);
}
fn create_issue(c: web::Ctx&) {
    guard ready(c) else { return; }
    let input, ok = body<IssueInput>(c); guard ok else { return; }
    if !status_valid(input.status) { c.fail(web::HTTP_UNPROCESSABLE_CONTENT, "invalid_payload", "Status must be open, in_progress, or closed"); return; }
    let _, parent = web::find_row<Project>(database, input.project_id);
    if !parent { missing(c, "project"); return; }
    var item = Issue { id: 0, project_id: input.project_id, title: input.title, status: input.status };
    let id, inserted = web::insert(database, item);
    if !inserted { failed(c); return; }
    item.id = id; c.status(web::HTTP_CREATED).json(item);
}
fn get_issue(c: web::Ctx&) {
    guard ready(c) else { return; }
    let id, ok = c.param_int("id"); guard ok else { return; }
    let item, found = web::find_row<Issue>(database, id);
    if !found { missing(c, "issue"); return; } c.json(item);
}
fn patch_issue(c: web::Ctx&) {
    guard ready(c) else { return; }
    let id, ok = c.param_int("id"); guard ok else { return; }
    var input, result = web::body_decode<IssuePatch>(c);
    guard web::validate_result(c, "body", input, result) else { return; }
    if web::has<IssuePatch>(result, "status") && !status_valid(input.status) {
        c.fail(web::HTTP_UNPROCESSABLE_CONTENT, "invalid_payload", "Status must be open, in_progress, or closed"); return;
    }
    let item, found = web::find_row<Issue>(database, id);
    if !found { missing(c, "issue"); return; }
    let has_title = web::has<IssuePatch>(result, "title");
    let has_status = web::has<IssuePatch>(result, "status");
    if !has_title && !has_status { c.fail(web::HTTP_UNPROCESSABLE_CONTENT, "invalid_payload", "Provide title or status"); return; }
    let old_status = item.status;
    var updated = item;
    if has_title { updated.title = input.title; }
    if has_status { updated.status = input.status; }
    if has_status && old_status != updated.status {
        let valid = (old_status == "open" && updated.status == "in_progress") ||
            (old_status == "in_progress" && (updated.status == "open" || updated.status == "closed")) ||
            (old_status == "closed" && updated.status == "open");
        if !valid { c.fail(web::HTTP_CONFLICT, "invalid_transition", "Issue status transition is not allowed"); return; }
    }
    if !web::update(database, updated) { failed(c); return; } c.json(updated);
}
fn delete_issue(c: web::Ctx&) {
    guard ready(c) else { return; }
    let id, ok = c.param_int("id"); guard ok else { return; }
    let _, found = web::find_row<Issue>(database, id);
    if !found { missing(c, "issue"); return; }
    if !web::remove<Issue>(database, id) { failed(c); return; } c.no_content();
}

fn mount(c: web::Ctx&) {
    c.group("/projects") {
        web::summary(c, "List projects"); web::returns_list<Project>(c, web::HTTP_OK); c.get("/") { list_projects(c); };
        web::summary(c, "Create a project"); web::accepts<ProjectInput>(c); web::returns<Project>(c, web::HTTP_CREATED); c.post("/") { create_project(c); };
        web::summary(c, "Get a project"); web::returns<Project>(c, web::HTTP_OK); c.get("/:id") { get_project(c); };
        web::summary(c, "Update a project's name or description"); web::accepts<ProjectPatch>(c); web::returns<Project>(c, web::HTTP_OK); c.patch("/:id") { patch_project(c); };
        web::summary(c, "Delete a project"); web::returns_empty(c, web::HTTP_NO_CONTENT); c.delete("/:id") { delete_project(c); };
    };
    c.group("/issues") {
        web::summary(c, "List issues"); web::returns_list<Issue>(c, web::HTTP_OK); c.get("/") { list_issues(c); };
        web::summary(c, "Create an issue"); web::accepts<IssueInput>(c); web::returns<Issue>(c, web::HTTP_CREATED); c.post("/") { create_issue(c); };
        web::summary(c, "Get an issue"); web::returns<Issue>(c, web::HTTP_OK); c.get("/:id") { get_issue(c); };
        web::summary(c, "Update issue title or transition status"); web::accepts<IssuePatch>(c); web::returns<Issue>(c, web::HTTP_OK); c.patch("/:id") { patch_issue(c); };
        web::summary(c, "Delete an issue"); web::returns_empty(c, web::HTTP_NO_CONTENT); c.delete("/:id") { delete_issue(c); };
    };
}
