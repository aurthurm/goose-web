import src.http.types;
import std;
namespace web;

// Before(request, response) returns whether Handler should run. After always
// runs, including on rejection. Wrap another pipeline in a named Handler to
// compose layers; their After callbacks unwind from the inner layer outward.
fn pipeline<Before, Handler, After>(request: Request, result: Response&) {
    if Before(request, result) { Handler(request, result); }
    After(request, result);
}
