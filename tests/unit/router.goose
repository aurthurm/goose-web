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
    // Wildcards: a final *name takes the nonempty rest of the path (slashes included, bytes raw).
    var files = web::router();
    assert(web::add_route(files, "GET", "/files/*path", 1));
    assert(!web::add_route(files, "GET", "/files/*other", 2));
    assert(!web::add_route(files, "GET", "/files/*a/b", 3));
    assert(!web::add_route(files, "GET", "/files/*a/", 3));
    assert(!web::add_route(files, "GET", "/*", 3));
    assert(!web::add_route(files, "GET", "/files/a*b/*", 3));
    assert(!web::add_route(files, "GET", "/:x/*x", 3));
    result = web::match_route(files, "GET", "/files/a/b/c.txt?x=1");
    assert(result.status == 200 && result.handler_id == 1 && web::path_param(result, "path") == "a/b/c.txt");
    var encoded = web::match_route(files, "GET", "/files/a%2Fb");
    assert(web::path_param(encoded, "path") == "a%2Fb");
    var empty_segments = web::match_route(files, "GET", "/files/x//y");
    assert(web::path_param(empty_segments, "path") == "x//y");
    assert(web::match_route(files, "GET", "/files/").status == 404);
    assert(web::match_route(files, "GET", "/files").status == 404);
    result = web::match_route(files, "POST", "/files/a");
    assert(result.status == 405 && result.allow == "GET, HEAD");
    assert(web::match_route(files, "HEAD", "/files/a").handler_id == 1);
    assert(web::add_route(files, "POST", "/files/*path", 4));
    assert(web::match_route(files, "POST", "/files/a").handler_id == 4);
    assert(web::match_route(files, "DELETE", "/files/a").allow == "GET, HEAD, POST");
    // A :param, then a static segment, each beat the wildcard at the same position.
    assert(web::add_route(files, "GET", "/files/:id", 5));
    assert(web::match_route(files, "GET", "/files/a").handler_id == 5);
    var nested = web::match_route(files, "GET", "/files/a/b");
    assert(web::path_param(nested, "path") == "a/b");
    assert(web::match_route(files, "GET", "/files/a/b").handler_id == 1);
    assert(web::add_route(files, "GET", "/files/new", 6));
    assert(web::match_route(files, "GET", "/files/new").handler_id == 6);
    assert(web::match_route(files, "POST", "/files/new").status == 405);
    assert(web::match_route(files, "POST", "/files/new").allow == "GET, HEAD");
    var rest_root = web::router();
    assert(web::add_route(rest_root, "GET", "/*any", 7));
    assert(web::match_route(rest_root, "GET", "/a/b/c").handler_id == 7);
    assert(web::match_route(rest_root, "GET", "/").status == 404);
    assert(web::add_route(rest_root, "GET", "/:x/b", 8));
    assert(web::match_route(rest_root, "GET", "/a/b").handler_id == 8);
    assert(web::match_route(rest_root, "GET", "/a/c").handler_id == 7);

    // Host scopes: exact and "*.example.com" (one label), ASCII case-insensitive, port stripped.
    var hosts = web::router();
    assert(web::add_route_host(hosts, "api.example.com", "GET", "/v1", 1));
    assert(web::add_route_host(hosts, "*.example.com", "GET", "/v1", 2));
    assert(web::add_route(hosts, "GET", "/v1", 3));
    assert(!web::add_route_host(hosts, "api.example.com", "GET", "/v1", 4));
    assert(!web::add_route_host(hosts, "API.example.com", "GET", "/v1", 4));
    assert(!web::add_route_host(hosts, "a..b", "GET", "/v1", 4));
    assert(!web::add_route_host(hosts, "*.", "GET", "/v1", 4));
    assert(!web::add_route_host(hosts, "*.*.example.com", "GET", "/v1", 4));
    assert(!web::add_route_host(hosts, "under_score.test", "GET", "/v1", 4));
    assert(!web::add_route_host(hosts, "example.com:80", "GET", "/v1", 4));
    assert(!web::add_route_host(hosts, "[::1]", "GET", "/v1", 4));
    assert(web::match_route_host(hosts, "GET", "/v1", "API.example.com:8080").handler_id == 1);
    assert(web::match_route_host(hosts, "GET", "/v1", "www.Example.com").handler_id == 2);
    assert(web::match_route_host(hosts, "GET", "/v1", "a.b.example.com").handler_id == 3);
    assert(web::match_route_host(hosts, "GET", "/v1", "example.com").handler_id == 3);
    assert(web::match_route_host(hosts, "GET", "/v1", "").handler_id == 3);
    assert(web::match_route(hosts, "GET", "/v1").handler_id == 3);
    assert(web::match_route_host(hosts, "GET", "/v1", "evilexample.com").handler_id == 3);
    var scoped = web::router();
    assert(web::add_route_host(scoped, "shop.test", "GET", "/only", 1));
    assert(web::match_route_host(scoped, "GET", "/only", "other.test").status == 404);
    assert(web::match_route_host(scoped, "GET", "/only", "shop.test:443").status == 200);
    assert(web::match_route_host(scoped, "POST", "/only", "shop.test").allow == "GET, HEAD");
    assert(web::match_route_host(scoped, "POST", "/only", "other.test").status == 404);
    // Path shape decides first; the host scope only breaks ties between equal shapes.
    var mixed = web::router();
    assert(web::add_route_host(mixed, "shop.test", "GET", "/items/:id", 1));
    assert(web::add_route(mixed, "GET", "/items/new", 2));
    assert(web::match_route_host(mixed, "GET", "/items/new", "shop.test").handler_id == 2);
    assert(web::match_route_host(mixed, "GET", "/items/9", "shop.test").handler_id == 1);
    assert(web::match_route_host(mixed, "GET", "/items/9", "x.test").status == 404);
    // Methods split across scopes: Allow lists the union for the request's host.
    var split = web::router();
    assert(web::add_route_host(split, "shop.test", "GET", "/x", 1));
    assert(web::add_route(split, "POST", "/x", 2));
    assert(web::match_route_host(split, "POST", "/x", "shop.test").handler_id == 2);
    assert(web::match_route_host(split, "GET", "/x", "shop.test").handler_id == 1);
    result = web::match_route_host(split, "GET", "/x", "other.test");
    assert(result.status == 405 && result.allow == "POST");
    assert(web::match_route_host(split, "DELETE", "/x", "shop.test").allow == "GET, HEAD, POST");
    assert(web::match_route_host(split, "DELETE", "/x", "other.test").allow == "POST");

    print("Router tests passed: specificity, parameters, methods, HEAD, bounds, query decoding, wildcards, host scopes");
}
