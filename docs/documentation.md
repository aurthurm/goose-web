# Documentation approach and maintenance

Goose Web documentation serves two readers: someone building a first application and someone
looking up an exact behavior. The [guide index](README.md) separates those paths from the
[API reference](api.md), architecture and contributor notes.

## Research used for the structure

The following official framework documentation was reviewed on 24 October 2026. These are
organizational examples, not claims that Goose Web implements their APIs:

- [FastAPI's tutorial](https://fastapi.tiangolo.com/tutorial/) progresses from first steps through
  typed input, middleware, bigger applications and testing, while keeping a separate reference.
  Goose Web follows that progression and links each guide to its exact API contract.
- [Flask's tutorial](https://flask.palletsprojects.com/en/stable/tutorial/) develops one modular
  application across layout, persistence, views, tests and deployment. Goose Web's Issue Board
  supplies a comparable worked example of module boundaries and a single entry point.
- [Django's overview](https://docs.djangoproject.com/en/5.2/intro/overview/) presents a quick
  introduction and then directs readers to tutorials and detailed documentation. The README
  gives that short orientation before the guidebook.
- [Phoenix's overview](https://hexdocs.pm/phoenix/overview.html) connects project conventions,
  application structure and the development workflow. Goose Web makes its smaller set of
  conventions explicit in project tooling and structure guides.

Goose Web's own language, compiler and runtime remain the source of truth for its examples.
The guides do not introduce a manifest parser, migration CLI, async model, ORM relationship layer
or globally installed framework command that the implementation does not provide.

## What belongs where

| Material | Location |
| --- | --- |
| Product description and first successful run | Root README |
| Installation and task walkthroughs | `docs/guide/` |
| Signatures, bounds, return values and exact failures | `docs/api.md` |
| Runnable applications and their commands | `examples/` |
| Short hosted overview | `docs/site/` |
| Design rationale, CI, release steps and security audit | Separate reference documents |

Guides link to the source and reference rather than copying every constant. Complete programs
include package declarations and startup. Fragments name the context they require. Text capacities
are bytes even when a validation length counts characters. Explicitly distinguish main-only APIs
from `v0.6.0`; the current starter imports its matching checkout by default.

## Check documentation changes

```sh
python3 manage.py docs
python3 manage.py ci
```

The link checker checks Markdown file targets, heading fragments and explicit HTML anchors in
local linked pages. It skips fenced code and external URLs; it is not an external-link availability
monitor or a full Markdown renderer. The suite checks the command wrapper and generator, builds
examples and exercises the starter and Issue Board over real sockets. Standalone guide snippets
should additionally be compiled when changed; partial snippets need the context stated on the page.

Keep the static site linked to the guidebook. The Pages workflow publishes `docs/site`; it does
not automatically render arbitrary Markdown files. GitHub renders the linked Markdown guides.
