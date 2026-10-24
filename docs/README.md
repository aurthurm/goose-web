# Goose Web documentation

Build an HTTP application in Goose, then grow it into separate modules with typed inputs,
SQLite persistence, templates, background work and operational controls.

These guides describe the current checkout. **The published `v0.6.0` tag predates validation rules,
typed settings, shared state, jobs and custom TCP.** Use the matching local checkout for those
features. [Release notes](../CHANGELOG.md) identify changes; do not mix a current starter with an
older framework tag. The [documentation site](https://aurthurm.github.io/goose-web/) is a shorter
overview; these Markdown guides and the reference contain the detailed instructions.

## Start here

1. [Getting started](guide/getting-started.md): install the compiler, build a first app, call it.
2. [Project commands](guide/project-tooling.md): generate a project, develop, build, test and run CI.
3. [Routing](guide/routing.md): groups, parameters, hosts and method matching.
4. [Requests and responses](guide/requests-and-responses.md): JSON, queries, forms and errors.
5. [Validation](guide/validation.md): constraints, PATCH presence and structured 422 details.
6. [Project structure](guide/project-structure.md): one executable entry point, many application modules.

Run [Issue Board](../examples/issue-board/README.md) to see the pieces together: projects and
issues, SQLite migrations, typed settings, validation, business rules and generated OpenAPI.

## Guides by task

| Task | Guide |
| --- | --- |
| Wrap handlers and control request order | [Middleware](guide/middleware.md) |
| Read environment variables and mounted secrets | [Settings](guide/settings.md) |
| Persist typed records and evolve a schema | [SQLite](guide/database.md) |
| Render HTML, layouts, forms and flash messages | [Templates](guide/templates.md) |
| Add sessions, CSRF, authentication and proxy trust | [Security](guide/security.md) |
| Generate `/openapi.json` and `/docs` | [OpenAPI](guide/openapi.md) |
| Schedule tasks and offload CPU work | [Background jobs](guide/background-jobs.md) |
| Publish application events and SSE streams | [Events and streaming](guide/events-and-streaming.md) |
| Share volatile state between worker processes | [Shared state](guide/shared-state.md) |
| Build a custom socket protocol | [TCP](guide/tcp.md) |
| Check code, exercise HTTP and configure CI | [Testing](guide/testing.md) |
| Configure workers, limits, signals and observability | [Deployment](guide/deployment.md) |
| Diagnose common build and application failures | [Troubleshooting](guide/troubleshooting.md) |

## Reference and contributor material

- [API reference](api.md): precise signatures, defaults, return values, limits and error behavior.
- [Public constants](constants.md): HTTP statuses, method names, capacities and runtime defaults.
- [HTTP conformance](http-conformance.md): accepted request profile and protocol limits.
- [Architecture](architecture.md): runtime, memory, native boundary and concurrency model.
- [Security review](security.md): threat model, findings and remaining limitations.
- [Compiler and CI setup](ci.md), [releases](releasing.md), [contributing](../CONTRIBUTING.md).
- [Documentation approach](documentation.md): research sources and maintenance conventions.

Guide snippets marked as fragments need the surrounding application described on that page.
For runnable programs, use the linked examples. Guides explain workflows; the API reference owns
the exact contract. Run `python3 manage.py docs` to check local links after editing documentation.
