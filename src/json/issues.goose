// Validation issues: every field-level problem found while decoding or checking one value, in
// the order found. Shared by the JSON codec (which collects decode problems) and the validation
// layer (src/app/validation.goose). Bounded: at most 16 issues are kept; later ones set
// `truncated`, so memory never grows with the input.
//
// kind is a Pydantic error type id (string_too_short, less_than_equal, missing, ...) and msg is
// the Pydantic-shaped English text. loc is the dotted field path ("" for the whole value,
// "address.zip" for a nested field); root is the source ("body", "query", "form", "settings").
import std;
namespace web;

struct Issue { loc: u8[..96], kind: u8[..24], msg: u8[..160] }
struct Issues { root: u8[..16], items: Issue[..16], truncated: bool }

// Copies text into a bounded string, cut to its capacity.
fn issue_put<T>(dst: T&, text: const u8[:]) {
    dst.clear();
    let n = if text.len > dst.cap { dst.cap } else { text.len };
    dst.append(text[..n]);
}

// Adds one issue, or sets truncated when the list is full.
fn issue_add(out: Issues&, loc: const u8[:], kind: const u8[:], msg: const u8[:]) {
    if out.items.len == out.items.cap {
        out.truncated = true;
        return;
    }
    var item = Issue { .. };
    issue_put(item.loc, loc);
    issue_put(item.kind, kind);
    issue_put(item.msg, msg);
    out.items.push(item);
}

// Sets the root name every issue is reported under.
fn issues_root(out: Issues&, root: const u8[:]) {
    issue_put(out.root, root);
}
