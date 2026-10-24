// Field rules and validation: every builder and type id, code-point lengths, nested structs,
// required and missing fields, failed fields, truncation, check_rules errors, the normalize and
// validate_model hooks, query and body 422 envelopes, and settings from the environment.
// Settings read GW_VT_* variables that tests/run.py sets (see the expectations in settings_test).
import goose_web from "../..";
import std;

struct Address { zip: u8[..8], code: i64 = 0 }
struct RequiredChild { value: i64 = 2, sibling: i64 = 0 }
struct Parent { child: RequiredChild }
struct Batch { children: RequiredChild[..65] }
struct Unsigned { value: u64 = 0 }
struct FloatMultiple { value: f64 = 0.0 }
struct Defaults { port: i64 = 0 }
struct SecretBound { name: u8[..8] = "" }
struct Sample {
    name: u8[..8], age: i64 = 0, ratio: f64 = 0.0, tags: u8[..4][..3], email: u8[..40],
    site: u8[..80], slug: u8[..24], id: u8[..36], digits: u8[..8], hex: u8[..8], alnum: u8[..8],
    motto: u8[..16], count: i32 = 0, small: i8 = 0, big: u64 = 0, home: Address,
}
struct Crowd {
    f00: i64 = 0, f01: i64 = 0, f02: i64 = 0, f03: i64 = 0, f04: i64 = 0, f05: i64 = 0,
    f06: i64 = 0, f07: i64 = 0, f08: i64 = 0, f09: i64 = 0, f10: i64 = 0, f11: i64 = 0,
    f12: i64 = 0, f13: i64 = 0, f14: i64 = 0, f15: i64 = 0, f16: i64 = 0, f17: i64 = 0,
}
struct Hooked { name: u8[..8], total: i64 = 0 }
struct QueryFlags { flag: bool = false, n: i64 = 0 }
struct Environment {
    port: i64 = 1, debug: bool = false, name: u8[..8] = "", token: u8[..32] = "", level: i64 = 0,
    key: u8[..8] = "", pin: i64 = 0, site: u8[..16] = "",
}
// Each check_rules case is its own struct, so one bad table cannot hide another.
struct BadUnknown { a: i64 = 0 }
struct BadDuplicate { a: i64 = 0 }
struct BadBounds { s: u8[..8] = "", n: i64 = 0 }
struct BadCapacity { s: u8[..4] = "" }
struct BadRange { n: i64 = 0 }

fn web::rules(v: RequiredChild&, r: web::Rules&) {
    r.field("value").required().ge(1);
    r.field("sibling").ge(1);
}
fn web::json_read_value(d: web::JsonDecoder&, v: RequiredChild&) { web::json_read_fields(d, v); }
fn web::check_value(v: RequiredChild&, rule: web::FieldRule&, path: const u8[:], out: web::Issues&) {
    web::validate_nested(v, path, out);
}
fn web::rules(v: Unsigned&, r: web::Rules&) { r.field("value").multiple_of(2).le(9223372036854775807); }
fn web::rules(v: FloatMultiple&, r: web::Rules&) { r.field("value").multiple_of(2); }
fn web::rules(v: Defaults&, r: web::Rules&) { r.field("port").ge(1); }
fn web::rules(v: SecretBound&, r: web::Rules&) { r.field("name").min_len(8).secret(); }

fn web::rules(v: Address&, r: web::Rules&) {
    r.field("code").ge(0).le(99);
}
fn web::rules(v: Sample&, r: web::Rules&) {
    r.field("name").required().min_len(2).max_len(8);
    r.field("age").gt(17).lt(120);
    r.field("ratio").gt(0).le(1);
    r.field("tags").min_items(1).max_items(2);
    r.field("email").format(web::FORMAT_EMAIL);
    r.field("site").format(web::FORMAT_URI);
    r.field("slug").pattern(web::PATTERN_SLUG);
    r.field("id").pattern(web::PATTERN_UUID);
    r.field("digits").pattern(web::PATTERN_DIGITS);
    r.field("hex").pattern(web::PATTERN_HEX);
    r.field("alnum").pattern(web::PATTERN_ASCII_ALNUM);
    r.field("motto").max_len(5);
    r.field("count").multiple_of(5);
    r.field("small").ge(-5).le(5);
    r.field("big").le(100);
}
fn web::rules(v: Hooked&, r: web::Rules&) {
    r.field("name").max_len(8);
}
fn web::rules(v: QueryFlags&, r: web::Rules&) {
    r.field("flag").lax();
    r.field("n").ge(1);
}
fn web::rules(v: Environment&, r: web::Rules&) {
    r.field("port").ge(1).le(65535);
    r.field("token").required().min_len(4).secret();
    r.field("pin").ge(1000).secret();
    r.field("site").required();
}
fn web::rules(v: Crowd&, r: web::Rules&) {
    r.field("f00").ge(1); r.field("f01").ge(1); r.field("f02").ge(1); r.field("f03").ge(1);
    r.field("f04").ge(1); r.field("f05").ge(1); r.field("f06").ge(1); r.field("f07").ge(1);
    r.field("f08").ge(1); r.field("f09").ge(1); r.field("f10").ge(1); r.field("f11").ge(1);
    r.field("f12").ge(1); r.field("f13").ge(1); r.field("f14").ge(1); r.field("f15").ge(1);
    r.field("f16").ge(1); r.field("f17").ge(1);
}
fn web::rules(v: BadUnknown&, r: web::Rules&) { r.field("zz").ge(1); }
fn web::rules(v: BadDuplicate&, r: web::Rules&) { r.field("a").ge(1); r.field("a").le(3); }
fn web::rules(v: BadBounds&, r: web::Rules&) { r.field("s").min_len(5).max_len(2); r.field("n").ge(5).le(1); }
fn web::rules(v: BadCapacity&, r: web::Rules&) { r.field("s").max_len(10); }
fn web::rules(v: BadRange&, r: web::Rules&) { r.field("n").gt(3).lt(3); }

// Registrations for the nested struct: decode, and the validation of its fields.
fn web::json_read_value(d: web::JsonDecoder&, out: Address&) { web::json_read_fields(d, out); }
fn web::check_value(v: Address&, rule: web::FieldRule&, path: const u8[:], out: web::Issues&) {
    web::validate_nested(v, path, out);
}

// Hooks: normalize upper-cases the name; validate_model refuses BAD after normalization.
fn web::normalize(v: Hooked&) {
    for i in v.name.len {
        if v.name[i] >= 'a' && v.name[i] <= 'z' { v.name[i] -= 32; }
    }
}
fn web::validate_model(v: Hooked&, out: web::Issues&) {
    if v.name[..] == "BAD" { web::issue_add(out, "", "value_error", "name must not be BAD"); }
}

// Every field of Sample valid.
fn good() -> Sample {
    var s = Sample { .. };
    s.name = "ann";
    s.age = 30;
    s.ratio = 0.5;
    s.tags.push("a");
    s.email = "ann@example.com";
    s.site = "https://example.com/a";
    s.slug = "good-slug";
    s.id = "123e4567-e89b-12d3-a456-426614174000";
    s.digits = "123";
    s.hex = "ff00";
    s.alnum = "Ab1";
    s.motto = "ééééé";
    s.count = 10;
    s.small = 1;
    s.big = 50;
    s.home.zip = "12345";
    s.home.code = 7;
    return s;
}

fn run_validate(s: Sample&) -> web::Issues {
    var out = web::Issues { .. };
    web::validate(s, "body", out);
    return out;
}

// The issue lists are taken by value, so a call may pass a temporary.
fn has_issue(out: web::Issues, loc: const u8[:], kind: const u8[:]) -> bool {
    for i in out.items.len {
        if out.items[i].loc[..] == loc && out.items[i].kind[..] == kind { return true; }
    }
    return false;
}

fn has_message(out: web::Issues, loc: const u8[:], message: const u8[:]) -> bool {
    for i in out.items.len {
        if out.items[i].loc[..] == loc && out.items[i].msg[..] == message { return true; }
    }
    return false;
}

fn test_valid_sample() {
    var s = good();
    let out = run_validate(s);
    assert(out.items.len == 0 && !out.truncated);
}

fn test_text_lengths_count_code_points() {
    var s = good();
    s.name = "é";
    assert(has_issue(run_validate(s), "name", "string_too_short"));
    s = good();
    s.name = "éééé";
    assert(run_validate(s).items.len == 0);
    s = good();
    s.motto = "éééééé";
    let out = run_validate(s);
    assert(has_message(out, "motto", "String should have at most 5 characters"));
    s = good();
    s.motto = "éééééé";
    assert(has_issue(run_validate(s), "motto", "string_too_long"));
}

fn test_text_patterns_and_formats() {
    var s = good();
    s.slug = "Bad_Slug";
    assert(has_issue(run_validate(s), "slug", "string_pattern_mismatch"));
    s = good();
    s.slug = "-lead";
    assert(has_issue(run_validate(s), "slug", "string_pattern_mismatch"));
    s = good();
    s.id = "123e4567-e89b-12d3-a456-42661417400";
    assert(has_issue(run_validate(s), "id", "string_pattern_mismatch"));
    s = good();
    s.digits = "12a";
    assert(has_issue(run_validate(s), "digits", "string_pattern_mismatch"));
    s = good();
    s.hex = "xyz";
    assert(has_issue(run_validate(s), "hex", "string_pattern_mismatch"));
    s = good();
    s.alnum = "a-b";
    assert(has_issue(run_validate(s), "alnum", "string_pattern_mismatch"));
    s = good();
    s.email = "nope";
    assert(has_issue(run_validate(s), "email", "value_error"));
    s = good();
    s.email = "a..b@example.com";
    assert(has_issue(run_validate(s), "email", "value_error"));
    s = good();
    s.site = "ftp://example.com";
    assert(has_issue(run_validate(s), "site", "value_error"));
    s = good();
    s.digits = "";
    assert(run_validate(s).items.len == 0);
}

fn test_numbers() {
    var s = good();
    s.age = 17;
    assert(has_issue(run_validate(s), "age", "greater_than"));
    s = good();
    s.age = 120;
    assert(has_issue(run_validate(s), "age", "less_than"));
    s = good();
    s.ratio = 0.0;
    assert(has_issue(run_validate(s), "ratio", "greater_than"));
    s = good();
    s.ratio = 1.5;
    assert(has_issue(run_validate(s), "ratio", "less_than_equal"));
    s = good();
    s.count = 7;
    assert(has_issue(run_validate(s), "count", "multiple_of"));
    s = good();
    s.small = -6;
    assert(has_issue(run_validate(s), "small", "greater_than_equal"));
    s = good();
    s.small = 6;
    assert(has_issue(run_validate(s), "small", "less_than_equal"));
    s = good();
    s.big = 101;
    assert(has_issue(run_validate(s), "big", "less_than_equal"));
}

fn test_lists() {
    var s = good();
    s.tags.clear();
    assert(has_issue(run_validate(s), "tags", "too_short"));
    s = good();
    s.tags.push("b");
    s.tags.push("c");
    assert(has_issue(run_validate(s), "tags", "too_long"));
}

fn test_nested_struct() {
    var s = good();
    s.home.code = 100;
    let out = run_validate(s);
    assert(has_issue(out, "home.code", "less_than_equal"));
    assert(out.items.len == 1);
}

fn test_required_and_missing() {
    var s = good();
    var out = web::Issues { .. };
    // Bit 0 is name: clearing it marks the field absent.
    web::validate_present(s, "body", 18446744073709551614, 0, out);
    assert(has_message(out, "name", "Field required"));
    assert(has_issue(out, "name", "missing"));
    // A field the decoder rejected is not checked again.
    s = good();
    s.name = "";
    var failed = web::Issues { .. };
    web::validate_present(s, "body", 18446744073709551615, 1, failed);
    assert(failed.items.len == 0);
}

fn test_truncation() {
    var c = Crowd { .. };
    var out = web::Issues { .. };
    web::validate(c, "body", out);
    assert(out.items.len == 16);
    assert(out.truncated);
    assert(has_issue(out, "f00", "greater_than_equal"));
}

fn test_check_rules() {
    let good_ok, good_msg = web::check_rules<Sample>();
    assert(good_ok && good_msg.len == 0);
    let a, am = web::check_rules<BadUnknown>();
    assert(!a && am == "unknown field: zz");
    let b, bm = web::check_rules<BadDuplicate>();
    assert(!b && bm == "duplicate rule for field: a");
    let c, cm = web::check_rules<BadBounds>();
    assert(!c && cm == "min_len is above max_len: s");
    let d, dm = web::check_rules<BadCapacity>();
    assert(!d && dm == "max_len is above the capacity of field: s");
    let e, em = web::check_rules<BadRange>();
    assert(!e && em == "gt is not below lt: n");
}

fn test_hooks() {
    var h = Hooked { .. };
    h.name = "bad";
    web::normalize(h);
    assert(h.name == "BAD");
    var out = web::Issues { .. };
    web::validate(h, "body", out);
    assert(has_message(out, "", "name must not be BAD"));
    // The decoder's rejected fields are not checked, and a normalized good name passes.
    var ok = Hooked { .. };
    ok.name = "fine";
    web::normalize(ok);
    var clean = web::Issues { .. };
    web::validate(ok, "body", clean);
    assert(clean.items.len == 0);
}

// Each context borrows the shared response; a test finishes with one before the next.
var shared_response = web::response();
var shared_scratch = web::AppScratch { .. };

fn query_ctx(target: const u8[:]) -> web::Ctx {
    shared_response = web::response();
    return web::new_ctx(web::Request { method: "GET", target: target, body: "", raw_headers: "Host: x\r\n" }, shared_response, shared_scratch);
}

fn body_ctx(text: const u8[:]) -> web::Ctx {
    shared_response = web::response();
    return web::new_ctx(web::Request { method: "POST", target: "/x", body: text, raw_headers: "Host: x\r\nContent-Type: application/json\r\n" }, shared_response, shared_scratch);
}

fn test_query_lax_and_422() {
    var c = query_ctx("/x?flag=yes&n=2");
    let q, ok = web::query<QueryFlags>(c);
    assert(ok && q.flag && q.n == 2);

    var strict = query_ctx("/x?flag=maybe");
    let s, sok = web::query<QueryFlags>(strict);
    assert(!sok);
    assert(strict.response.status == web::HTTP_BAD_REQUEST);

    var low = query_ctx("/x?n=0");
    let l, lok = web::query<QueryFlags>(low);
    assert(!lok && low.response.status == web::HTTP_UNPROCESSABLE_CONTENT);
    assert(find(web::body_of(low.response), "\"code\":\"invalid_query\"") >= 0);
    assert(find(web::body_of(low.response), "\"message\":\"n: Input should be greater than or equal to 1\"") >= 0);
    assert(find(web::body_of(low.response), "\"loc\":[\"query\",\"n\"]") >= 0);
    assert(find(web::body_of(low.response), "\"truncated\":false") >= 0);
}

// The 422 envelope for a body: detail for every issue, decode and constraint alike.
fn test_body_detail_envelope() {
    var c = body_ctx("{\"name\":\"a\",\"age\":5,\"tags\":[],\"home\":{\"code\":200},\"extra\":1}");
    let s, ok = web::body<Sample>(c);
    assert(!ok && c.response.status == web::HTTP_UNPROCESSABLE_CONTENT);
    let text = web::body_of(c.response);
    assert(find(text, "\"code\":\"invalid_payload\"") >= 0);
    assert(find(text, "\"message\":\"extra: Extra inputs are not permitted\"") >= 0);
    assert(find(text, "{\"loc\":[\"body\",\"extra\"],\"msg\":\"Extra inputs are not permitted\",\"type\":\"extra_forbidden\"}") >= 0);
    assert(find(text, "{\"loc\":[\"body\",\"name\"],\"msg\":\"String should have at least 2 characters\",\"type\":\"string_too_short\"}") >= 0);
    assert(find(text, "{\"loc\":[\"body\",\"age\"],\"msg\":\"Input should be greater than 17\",\"type\":\"greater_than\"}") >= 0);
    assert(find(text, "{\"loc\":[\"body\",\"home\",\"code\"],\"msg\":\"Input should be less than or equal to 99\",\"type\":\"less_than_equal\"}") >= 0);
    assert(find(text, "\"truncated\":false}") >= 0);
}

// Malformed JSON stays a 400, with no detail list.
fn test_body_syntax_is_400() {
    var c = body_ctx("{\"name\":");
    let s, ok = web::body<Sample>(c);
    assert(!ok && c.response.status == web::HTTP_BAD_REQUEST);
    assert(find(web::body_of(c.response), "\"detail\"") < 0);
}

// Settings come from GW_VT_* variables set by tests/run.py:
//   GW_VT_PORT=8080, GW_VT_DEBUG=yes, GW_VT_NAME=ann, GW_VT_TOKEN_FILE=<fixture>, GW_VT_LEVEL=x,
//   GW_VT_KEY=abc and GW_VT_KEY_FILE=<fixture> (both set), GW_VT_PIN=abc. GW_VT_SITE is unset.
fn test_settings() {
    var env, issues = web::settings<Environment>("GW_VT_");
    assert(env.port == 8080);
    assert(env.debug);
    assert(env.name == "ann");
    assert(env.token == "file-secret");
    assert(has_issue(issues, "level", "value_error"));
    assert(has_message(issues, "key", "set either the variable or its _FILE variable, not both"));
    assert(has_message(issues, "pin", "invalid value (redacted)"));
    assert(has_issue(issues, "site", "missing"));
    assert(issues.root == "settings");
    assert(!has_issue(issues, "port", "value_error"));
}

// A settings value that breaks a bound reports the bound, and never the secret's text.
fn test_settings_redaction() {
    var env, issues = web::settings<Environment>("GW_VT_");
    for i in issues.items.len {
        assert(find(issues.items[i].msg[..], "abc") < 0);
    }
}

fn test_nested_presence_and_partial_errors() {
    var missing = body_ctx("{\"child\":{\"sibling\":2}}");
    let a, aok = web::body<Parent>(missing);
    assert(!aok);
    assert(find(web::body_of(missing.response), "\"loc\":[\"body\",\"child\",\"value\"],\"msg\":\"Field required\"") >= 0);
    var partial = body_ctx("{\"child\":{\"value\":\"wrong\",\"sibling\":0}}");
    let b, bok = web::body<Parent>(partial);
    assert(!bok);
    let text = web::body_of(partial.response);
    assert(find(text, "\"type\":\"int_type\"") >= 0);
    assert(find(text, "\"loc\":[\"body\",\"child\",\"sibling\"]") >= 0);
    assert(find(text, "\"type\":\"greater_than_equal\"") >= 0);
}

fn test_nested_metadata_is_bounded_for_bodies_only() {
    var text: u8[>..] = [];
    text.append("{\"children\":[");
    for i in 65 {
        if i > 0 { text.push(','); }
        text.append("{\"value\":2,\"sibling\":2}");
    }
    text.append("]}");
    let decoded, result = web::json_decode<Batch>(text[..]);
    assert(result.ok && decoded.children.len == 65);
    var c = body_ctx(text[..]);
    let value, ok = web::body<Batch>(c);
    assert(!ok && c.response.status == web::HTTP_UNPROCESSABLE_CONTENT);
    assert(find(web::body_of(c.response), "Too many nested objects to validate") >= 0);
}

fn test_unsigned_bounds_and_multiples() {
    var huge = FloatMultiple { value: 1e300 };
    var clean = web::Issues { .. };
    web::validate(huge, "body", clean);
    assert(clean.items.len == 0);
    huge.value = 1.5;
    web::validate(huge, "body", clean);
    assert(has_issue(clean, "value", "multiple_of"));
    var v = Unsigned { value: 9223372036854775808 };
    var out = web::Issues { .. };
    web::validate(v, "body", out);
    assert(has_issue(out, "value", "less_than_equal"));
    assert(!has_issue(out, "value", "multiple_of"));
}

fn test_settings_defaults_and_secret_bounds() {
    let defaults, issues = web::settings<Defaults>("GW_VT_DEFAULT_");
    assert(has_issue(issues, "port", "greater_than_equal"));
    let secret, problems = web::settings<SecretBound>("GW_VT_");
    assert(has_message(problems, "name", "invalid value (redacted)"));
    assert(!has_message(problems, "name", "String should have at least 8 characters"));
}

fn test_bounded_issues_keep_utf8() {
    var text: u8[>..] = [];
    for i in 60 { text.append("é"); }
    var out = web::Issues { .. };
    web::issue_add(out, text[..], "value_error", text[..]);
    assert(web::valid_utf8(out.items[0].loc[..]));
    assert(out.items[0].loc.len == 96);
}

fn main() {
    test_nested_presence_and_partial_errors();
    test_unsigned_bounds_and_multiples();
    test_nested_metadata_is_bounded_for_bodies_only();
    test_settings_defaults_and_secret_bounds();
    test_bounded_issues_keep_utf8();
    test_valid_sample();
    test_text_lengths_count_code_points();
    test_text_patterns_and_formats();
    test_numbers();
    test_lists();
    test_nested_struct();
    test_required_and_missing();
    test_truncation();
    test_check_rules();
    test_hooks();
    test_query_lax_and_422();
    test_body_detail_envelope();
    test_body_syntax_is_400();
    test_settings();
    test_settings_redaction();
    print("Validation tests passed: rules, type ids, unicode lengths, nested, hooks, check_rules, 422 detail, settings");
}
