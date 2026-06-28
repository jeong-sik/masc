---
rfc: "0296"
title: "CI skip-gate main-push safety-net: always run Build and Test on non-PR events"
status: Draft
created: 2026-06-28
updated: 2026-06-28
author: vincent
supersedes: []
superseded_by: null
related: ["0270", "0206"]
implementation_prs: []
---

# RFC-0296: CI skip-gate main-push safety-net

Status: Draft · `Build and Test` must always run on non-PR events (push to
main/develop, workflow_dispatch) regardless of the changed-surface scope, so a
`lib/` regression introduced by a non-build-path merge is detected on the next
main push instead of persisting silently behind a green `CI Gate`.

> Anchors read against `origin/main` (`10152718aef`) on 2026-06-28.
> `lib/` and workflow line numbers shift; re-confirm against the merge-base
> before landing.

## §1 Problem

`main` is chronically red. On 2026-06-27 a 200-run sweep of the `CI` workflow
on `main` showed every `success` run had `Build and Test: skipped` (fake green),
while every `build=true` run failed (32 quick-suite tests across redaction,
dashboard projection, mcp e2e, keeper receipt, workspace, etc.). PRs #22386 and
#22388 failed with the identical 32-test set despite touching unrelated code —
the failures are inherited from `main`, not introduced by those PRs.

The defect class is a **fourth CI-gate hole**, distinct from RFC-0270 Hole 2
(the `ci-gate` job's `if: !cancelled()` making a cancelled run report
`cancelled`). This hole is in two compounding pieces of the same circuit:

**Piece A — `Build and Test` is path-scoped even on `main` push.**
`.github/workflows/ci.yml:557` gates the job on
`needs.changes.outputs.build == 'true'`. The `build` classifier (`ci.yml:236`)
matches `bin/|lib/|test/|proto/|...*.ml$` but not `dashboard/`. A dashboard-only
(or docs-only) merge produces a `main` push run with `build=false`, so
`Build and Test` is skipped. The repo already warns about this in a comment at
`ci.yml:236-252`: "any code-bearing PR that does NOT set build=true merges with
a green CI Gate while the Build job never ran."

**Piece B — `ci-gate` `check()` treats `skipped` as PASS.**
`ci.yml:1176`:
```bash
if [[ "$result" == "success" || "$result" == "skipped" ]]; then
  printf 'PASS  %-20s %s\n' "$name" "$result"
```
So a skipped `Build and Test` resolves to a green `CI Gate`, the sole required
check (RFC-0270 Hole 1). The regression reaches `main` with no merge-blocking
signal, and surfaces only when the next `lib/`-touching PR triggers a
`build=true` `main` push — by which point multiple regressions have accumulated
and the first-red commit is no longer recoverable from CI records.

The `dashboard` job already solves the same problem for its own surface
(`ci.yml:1004`, comment names it the "main-push safety-net pattern"): non-PR
events ignore path scope and always run. `Build and Test` lacks this safety-net.

## §2 Solution

**Step 1 (this RFC's scope) — Piece A.** Mirror the `dashboard` job's
safety-net in `Build and Test`. Change the `if` at `ci.yml:557` so non-PR events
run regardless of `changes.outputs.build`:

```yaml
if: ${{ always() && !cancelled()
  && needs.pr-live-gate.outputs.run_heavy == 'true'
  && needs.changes.result == 'success'
  && (needs.changes.outputs.build == 'true'
      || needs.pr-live-gate.outputs.live_state == 'NON_PR') }}
```

`live_state == 'NON_PR'` is set by `pr-live-gate` for non-PR events
(`ci.yml:78-86`): main/develop push and workflow_dispatch. The workflow `on:`
push trigger is restricted to `main`/`develop`, so tag pushes never reach here.
PR events keep the `build`-scope gate unchanged, preserving the CI-minutes cost
saving.

**Step 2 (follow-up, not in this RFC's first PR) — Piece B.** Change
`ci-gate` `check()` (`ci.yml:1176`) so a skipped required job is not PASS.
This is the more fundamental fix (closes the hole for every job and every entry
path, including future heavy jobs), but applied alone it would block
dashboard-only PR merges until `main` is green again. Land Step 2 only after
Step 1 is on `main` and `main` is restored to green.

**Step 3 (follow-up, defense-in-depth) — nightly safety-net.**
`main-nightly-health.yml:110-111` runs only `dune build @install` (compile, no
tests). Extend it to run the quick suite so a regression that still slips past
Steps 1-2 is caught within 24h (RFC-0270 §4.2 tripwire D, same layer).

This is a gate-circuit repair, not a workaround. Step 1 *removes* a path gate
for the main-push surface (the opposite of signature 2, substring-classifier
hardening); Steps 2-3 close the lying aggregator and add a time-bounded net.

## §3 Verification

1. The change PR itself sets `build=true`: `ci_core` (`ci.yml:232`) matches
   `.github/workflows/ci.yml`, and `ci.yml:310-324` force-emits `build=true`.
   No self-reference hole; no escape hatch needed.
2. After merge, a dashboard-only/docs-only merge to `main` must produce a
   `main` push run whose `Build and Test` job is **not** `skipped` — verify via
   `gh run view <run> --json jobs`.
3. Until `main` is green, Step 1 will flip dashboard-merge `main` runs from
   fake-green to red. That is the intended unmasking; `main` restoration is the
   prerequisite for Step 1's cost normalizing.

## §4 Related

- RFC-0270 (CI Gate merge guard) — this is its 4th hole; Hole 2 there
  (`ci.yml:1138`, cancelled run) is a different line and mechanism.
- RFC-0206 §102 R6 — prior CI surface-gate misclassification (types-only P1 →
  no-surface) on 2026-05-28; same `Detect Changed Surfaces` trust, different
  symptom.
