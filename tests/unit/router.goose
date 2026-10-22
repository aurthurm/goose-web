import goose_web from "../..";
import std;

fn main() {
    var routes = web::router();
    assert(web::add_route(routes, "GET", "/users/:id", 1));
    assert(web::add_route(routes, "POST", "/users/:id", 2));
    assert(web::add_route(routes, "GET", "/users/new", 3));
    assert(!web::add_route(routes, "GET", "/users/:other", 4));
    assert(!web::add_route(routes, "bad method", "/", 4));
    assert(web::add_route(routes, "M-SEARCH", "/custom", 40));
    assert(!web::add_route(routes, "GET\r\n", "/", 4));
    assert(!web::add_route(routes, "TOOLONGMETHODNAME!", "/", 4));
    assert(!web::add_route(routes, "GET", "/:id/:id", 4));
    assert(!web::add_route(routes, "GET", "relative", 4));
    assert(!web::add_route(routes, "GET", "/:bad-name", 4));
    var result = web::match_route(routes, "GET", "/users/123?sort=name");
    assert(result.status == 200 && result.handler_id == 1);
    assert(web::path_param(result, "id") == "123");
    assert(web::path_param(result, "missing") == "");
    assert(web::match_route(routes, "GET", "/users/new").handler_id == 3);
    assert(web::match_route(routes, "POST", "/users/new").status == 405);
    assert(web::match_route(routes, "GET", "/users/").status == 404);
    assert(web::match_route(routes, "GET", "/users/12/").status == 404);
    assert(web::match_route(routes, "GET", "/Users/12").status == 404);
    assert(web::match_route(routes, "HEAD", "/users/12").handler_id == 1);
    result = web::match_route(routes, "DELETE", "/users/12");
    assert(result.status == 405 && result.allow == "GET, HEAD, POST");
    assert(web::add_route(routes, "HEAD", "/users/:id", 5));
    assert(web::match_route(routes, "HEAD", "/users/12").handler_id == 5);
    assert(web::match_route(routes, "DELETE", "/users/12").allow == "GET, POST, HEAD");
    result = web::match_route(routes, "GET", "/users/a%2Fb");
    assert(web::path_param(result, "id") == "a%2Fb");

    // Earlier literal segments win, independently of registration order.
    assert(web::add_route(routes, "GET", "/:type/new", 6));
    assert(web::add_route(routes, "GET", "/users/:id", 7) == false);
    assert(web::match_route(routes, "GET", "/users/new").handler_id == 3);
    assert(web::add_route(routes, "GET", "/", 8));
    assert(web::match_route(routes, "GET", "/?x=1").handler_id == 8);
    assert(web::add_route(routes, "GET", "/a//b", 9));
    assert(web::match_route(routes, "GET", "/a//b").handler_id == 9);
    assert(web::match_route(routes, "GET", "/a/b").status == 404);
    assert(web::add_route(routes, "GET", "/:group/fixed", 10));
    assert(web::add_route(routes, "POST", "/things/:id", 11));
    assert(web::match_route(routes, "GET", "/things/fixed").status == 405);
    assert(web::match_route(routes, "POST", "/things/fixed").handler_id == 11);
    assert(web::add_route(routes, "GET", "/teams/:team/users/:user", 12));
    result = web::match_route(routes, "GET", "/teams/one/users/two");
    assert(result.param_count == 2 && web::path_param(result, "team") == "one");
    assert(web::path_param(result, "user") == "two");
    var long_pattern: u8[>..] = [];
    long_pattern.push('/');
    for i in 512 { long_pattern.push('x'); }
    assert(!web::add_route(routes, "GET", long_pattern, 99));
    var many_parameters: u8[>..] = [];
    for i in 16 { format(many_parameters, "/:p", i); }
    assert(web::add_route(routes, "GET", many_parameters, 13));
    many_parameters.append("/:overflow");
    assert(!web::add_route(routes, "GET", many_parameters, 14));
    var union = web::router();
    var accepted: i64 = 0;
    for i in 64 {
        var method: u8[>..] = [];
        format(method, "CUSTOMMETHOD", i);
        if web::add_route(union, method, "/", i as i32) { accepted += 1; }
    }
    assert(accepted > 0 && accepted < 64);
    assert(web::match_route(union, "GET", "/").allow.len <= 256);
    var full = web::router();
    for i in 64 {
        var pattern: u8[>..] = [];
        format(pattern, "/", i);
        assert(web::add_route(full, "GET", pattern, i as i32));
    }
    assert(!web::add_route(full, "GET", "/extra", 100));

    assert(web::target_path("/a?x=1?2") == "/a");
    assert(web::target_query("/a?x=1?2") == "x=1?2");
    assert(web::target_query("/a") == "");
    assert(web::query_value("/?q=hello+world%21", "q").value == "hello world!");
    assert(web::query_value("/?%71=%00%ff", "q").value == "\x00\xff");
    assert(web::query_value("/?q=first&q=second", "q").value == "first");
    assert(web::query_value("/?q&q=second", "q").status == 200);
    assert(web::query_value("/?q&q=second", "q").value == "");
    assert(web::query_value("/?q=a=b", "q").value == "a=b");
    assert(web::query_value("/?x=1", "q").status == 0);
    assert(web::query_value("/?q=ok&other=%", "q").status == 400);
    assert(web::query_value("/?q=%0z", "q").status == 400);
    assert(web::query_value("/?bad%=x", "q").status == 400);
    var target: u8[>..] = [];
    target.append("/?q=");
    for i in 1024 { target.push('x'); }
    assert(web::query_value(target, "q").status == 200);
    target.push('x');
    assert(web::query_value(target, "q").status == 413);
    print("Router tests passed: specificity, parameters, methods, HEAD, bounds, query decoding");
}
