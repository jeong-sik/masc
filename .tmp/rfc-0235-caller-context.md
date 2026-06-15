# RFC-0235 Caller Context

Source, 2026-06-13 merge audit (`~/me/reports/masc-merge-audit-2026-06-13.md`):

- Cross-cutting structural defect (finding task-947): a stale-base merge
  silently reverted sibling PRs four times in one 211-commit window.
- The keystone incident is `6f5bfdeb2` (#20869): it reverted #20853,
  #20859, and #20848; the #20853 telemetry block was dropped 19/19 lines
  with no git conflict.

Owner direction, 2026-06-14:

- Of the two audit-proposed options (merge-base freshness gate vs.
  diff revert-detection), implement the root fix, not a symptom heuristic.
- Hardcoded string-match / prose classifiers are not acceptable as the
  implementation.

Design constraints:

- Deterministic structural check on git objects only (no content
  classifier, no telemetry counter).
- Must not be noisy under the admin-merge / conveyor-belt cadence:
  fire only on the dangerous overlap (files the PR and main both touched
  where the branch lacks main's additions), not on mere staleness.
- The remedy must always be available (rebase) so the gate can block,
  not merely warn.
- Intentional reverts opt out via a structured label, not a body match.

Verification expectation:

- RFC numbering, ledger, and section-1 enforcer checks pass.
- The guard ships with a self-test that reconstructs the stale-base
  topology and is mutation-checked; the CI job runs the self-test before
  the guard.
- Does not change merge policy (squash-merge staleness, task-937 branch
  protection) — those remain separate.
