# bisect_ppx Coverage Closeout Runbook

This runbook is the evidence path for any goal that claims 100% OCaml line
coverage. A goal is not done because `*_coverage.ml` files exist, and it is not
done because stale `_coverage` files are present. It is done only when a fresh
bisect artifact for the target commit measures at or above the required
threshold.

## Closeout Gate

Use the repo wrapper so local and CI coverage use the same dependency and test
setup:

```bash
scripts/opam-pin-external-deps.sh --with-bisect
opam install . --deps-only --with-test
scripts/coverage_percent.sh --fail-under 100
```

The final command must be run from the target commit. It deletes and recreates
`_coverage` unless `--reuse-existing` is passed.

`--reuse-existing` is allowed only when the operator records all of these facts
beside the result:

- the exact commit SHA that produced `_coverage`
- the exact coverage command that produced it
- the `COVERAGE_DIR` path
- the timestamp of the coverage files
- a successful `scripts/coverage_percent.sh --reuse-existing --fail-under 100`
  run on the same checkout

If any fact is missing, regenerate coverage instead of reusing local files.

## Required Evidence

Attach or link this evidence before closing a 100% coverage goal:

| Evidence | Required content |
| --- | --- |
| Target revision | repo, branch, and full commit SHA |
| Tooling proof | `opam exec -- which bisect-ppx-report` output |
| Coverage command | exact `scripts/coverage_percent.sh --fail-under 100` command |
| Measured result | stdout percentage and exit status |
| Artifact path | `_coverage` or explicit `COVERAGE_DIR` path |
| CI relation | GitHub run/check name and head SHA for the same commit |

For GitHub issues, paste the above as a short comment. For PRs, put it in the
verification section so reviewers can see that the claim is tied to a measured
artifact.

## When Coverage Is Below 100

Do not close the parent goal. Create follow-up issues or keeper tasks from the
generated HTML report:

```bash
opam exec -- bisect-ppx-report html --coverage-path _coverage
```

Each follow-up must include:

- uncovered file and function/module name
- why the path is expected to be reachable
- the smallest intended test target
- the coverage command that will verify the fix
- links to the parent coverage goal and any PR that adds the test

Keep the parent issue open until `scripts/coverage_percent.sh --fail-under 100`
passes on the commit that contains the final coverage PR.

## Operator Checklist

- [ ] Reporter is installed: `opam exec -- which bisect-ppx-report`.
- [ ] Coverage was regenerated, or `--reuse-existing` has the required facts.
- [ ] `scripts/coverage_percent.sh --fail-under 100` passed.
- [ ] The measured percentage, commit SHA, and artifact path are recorded.
- [ ] Any uncovered surface has a linked follow-up issue/task.
- [ ] The closing comment names the PR/check that validated the same SHA.
