# Releasing

Goose Web follows [Semantic Versioning](https://semver.org/) with the 0.x caveat in
[CHANGELOG.md](../CHANGELOG.md): until 1.0.0 a minor release may break the public API, and
every break is listed under **Breaking** in the changelog entry.

Consumers fetch the repository with a tag, so a tag is the release. Goose resolves
`aurthurm/goose-web@vX.Y.Z` to that tag's commit and caches it under `~/.goose/pkg`. Tags are not
moved after publication; a mistake gets the next patch version.

## Checklist

1. **Version.** Set the same value in two places: the `VERSION` file (`X.Y.Z`, no `v`) and
   `const VERSION = "X.Y.Z";` in `src/constants/runtime.goose`. `python3 tests/run.py` fails when
   they differ.
2. **Changelog.** Move the notes into a `## X.Y.Z` section of `CHANGELOG.md` with the date, and
   list breaking changes under **Breaking** first. Public API changes are additive unless a break is
   documented here (see [CONTRIBUTING.md](../CONTRIBUTING.md)).
3. **Gate.** Run the full suite with both C compilers, as CI does (see [ci.md](ci.md)):

   ```sh
   python3 scripts/bootstrap_goose.py
   export GOOSE="$PWD/build/tools/goose/build/goose"
   export GOOSE_STDLIB="$PWD/build/tools/goose/source/stdlib"
   CC=gcc GOOSE_CC=gcc python3 manage.py ci
   CC=clang GOOSE_CC=clang python3 manage.py ci
   ```

   The Linux CI workflow must be green on the commit that will be tagged.
4. **Merge** the release commit to `main`.
5. **Tag** the merged commit with an annotated tag and push it:

   ```sh
   git tag -a vX.Y.Z -m "Goose Web X.Y.Z"
   git push origin vX.Y.Z
   ```

   The maintainer or release automation does this, not a feature branch.
6. **Verify the tag from outside the repository.** In an empty directory, write a program with
   `import goose_web from "aurthurm/goose-web@vX.Y.Z";`, run `goose fetch program.goose`, then
   `goose build` and run it. Check `web::VERSION` and `GET /health`. To test the starter against
   the published tag, explicitly generate with `python3 manage.py new smoke --source aurthurm/goose-web@vX.Y.Z`,
   then run `python3 manage.py ci` in that directory. The generator's default local checkout
   does not verify remote consumption.
7. **Publish the notes.** Create a GitHub release from the tag with the changelog section as its body.
8. **Site.** The Pages workflow (`.github/workflows/pages.yml`) republishes `docs/site` on each push to
   `main`. Update the version shown in `docs/site` when the release changes the documented API.

## The db package

`db/` is a subdirectory of this repository. The packages reference (`/opt/goose/docs/packages.md`,
section 2) describes a source as a repository, a commit, a URL or a directory, with no form for a
path inside a repository, so `aurthurm/goose-web/db@vX.Y.Z` is not a documented declaration. Consumers of `goose_web_db` declare the root package as well and point the second
import at a checkout's `db` directory (see [README](../README.md#use-it-in-your-project)). Splitting
it into its own repository would make it a normal fetched package; that is a separate decision.

## Pitfalls

- Never reuse or move a tag. `goose fetch --update` refreshes branches and tags that moved, but
  consumers who pinned a commit are unaffected, and everyone else gets the moved code silently.
- A branch name (`@main`) is not a release. Goose refreshes it only with `goose fetch --update`.
- Check that `VERSION`, the constant and the changelog heading agree before tagging.
