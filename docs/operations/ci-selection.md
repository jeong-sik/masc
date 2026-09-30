# Choose CI before spending runners

Ordinary PR creation and pushes do not start the required checks. Select a
specific merge candidate after implementation/review, or when the operator
requests that PR's checks:

```sh
bash scripts/ci/select-pr.sh <pr-number> jeong-sik/masc
```

The repository needs a `ci:run` label. The script adds it and transitions the PR
to ready (briefly through draft if it was already ready). Existing PR event
types are retained: adding an unrelated label does not supersede CI evidence.
Later pushes to the selected PR replace its older run. Remove `ci:run` when
the PR is no longer a candidate; cancel an already running check explicitly.
Skipped jobs on an unselected PR are not passing merge evidence.

Runner pools are shared across selected PRs: dev/release OCaml builds share
one slot; lint, dashboard, TLA and the required-success summary each have one
slot. `queue: max` preserves other selected jobs instead of replacing a pending
job with a different PR. GitHub limits each such queue to 100 pending jobs;
selection should keep the candidate set small.

Main and release verification retain their own workflows. Full behavioral Test
runs once daily at 02:43 KST. The broad platform baseline runs once daily at
03:13 KST through `daily-platform.yml`: macOS keychain, Antigravity transport,
browser hosts, installer, package images, portable Python, process groups, Kata
and benchmark harness tests. They share one proof slot. Platform workflows can
also be dispatched for a specific urgent regression; changing a PR no longer
starts all of these baselines. Benchmark artifact comparisons remain explicit
requests because they require chosen baseline/candidate artifacts.

Test, manual probe artifacts, dashboard artifacts and package-image dispatches
require `-f run_requested=true`. Their default is inert. Requested Test runs share
one slot; release-candidate and nightly Test runs have separate slots. Linux/macOS
probe and dashboard artifact builds share one artifact slot. Dispatch only the
missing evidence: a duplicate of a suite already selected by PR check is not needed.

```sh
gh workflow run test.yml --ref <branch> -f run_requested=true -f suite=<suite>
gh workflow run linux-x64-probe.yml --ref <branch> -f run_requested=true
gh workflow run apple-keychain.yml --ref <branch>
```

Use branches containing this policy. A dispatch of an older ref uses that ref's
old workflow definition. No run watcher or timer loop is part of this process.

## End the incident pause

On 2026-09-30 these workflows were temporarily disabled to stop incoming work
while the queue was cleared. Once this policy is on main, re-enable them before
new targeted, nightly or candidate verification:

```sh
gh workflow enable test.yml --repo jeong-sik/masc
gh workflow enable linux-x64-probe.yml --repo jeong-sik/masc
gh workflow enable dashboard-artifact.yml --repo jeong-sik/masc
gh workflow enable lane-addon-images.yml --repo jeong-sik/masc
gh workflow enable pr-check.yml --repo jeong-sik/masc
```

The macOS keychain run `36696218857` was preserved during cleanup and passed:
native read/clear, denied/locked/missing items, state restoration and concurrent
domains; `keychain_prompt_events` was empty. This is fixture CI evidence, not a
deployment observation.

References: [GitHub concurrency](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-workflow-concurrency),
[queue semantics](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#concurrency).
