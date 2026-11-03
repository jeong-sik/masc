# PR type-check path filter — landing and first observations (2026-11-03)

- `pr-type-check.yml` landed on `main` with #47871 (merged 2026-11-03T15:59:26Z)
  and was corrected by #47971 (merged 2026-11-03T16:10:39Z, commit 401cd2208fef):
  the workflow's own file path was added so the workflow re-runs when itself
  changes, and the motivation comment's PR/sha pair was fixed.
- Deliberately NOT a required status check (see the workflow header comment:
  a `paths:` filtered workflow produces no check context outside the filter,
  and a required check that never appears would block those PRs forever).
- Effective `pull_request` paths on main: `lib/**/*.{ml,mli}`, `bin/**/*.ml(i)`,
  `test/**/*.{ml,mli,inc}`, `test/**/dune`, `**/dune`, `dune-project`, `*.opam`,
  `.github/actions/**`, and only the self file
  `.github/workflows/pr-type-check.yml` — NOT `.github/workflows/**`.
- First `pull_request` runs (all one job: `dune build @check`):
  - success — run 41670160042 at 401cd2208fefe504414a1a28ed2af2d82ec982f7
    (#47971's own branch, 16:03:06Z; the merge ref carried the self path)
  - success — run 41672895713 at 45c13c0f0b9b9ea93cecab59c42f14ac686b52ec
    (#47965, 16:18:48Z)
  - success — run 41677829381 at 1a7723114279b661f6523486ead695d8d54ac6b1
    (#47715 draft, 16:47:47Z)
  - failure — run 41679095162 at 4749973e03f8a427ebb314c901f505317995247c
    (#47976 while rebased onto main, 16:55:26Z); log error:
    `Error: Unbound value schedules_changed` — the refs exist only on the
    stack branch, so the check did its job on a broken head.
- Correct non-trigger observations:
  - #47943 at 6e44264561be (pushed 16:22:02Z) touches
    `.github/workflows/main-minimal-build.yml`, `.github/workflows/test.yml`
    and a changelog fragment — none in `paths:`, so no run. Only the workflow's
    own file triggers it.
  - This draft PR itself is the docs-only non-execution case for task-3166 (3):
    docs-only changes must produce no `PR type-check` check-run.
- Written by goo-yang-bong (pangyo-preachers) for task-3166. The draft PR
  carrying this file is verification scaffolding for (3) and is closed right
  after the observation.
