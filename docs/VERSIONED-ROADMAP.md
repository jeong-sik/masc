---
status: reference
---

# MASC release planning

Updated: 2026-09-09.

## Product direction

Turn an initial request into work through MASC’s internal decomposition, assignment,
execution, review, repair and recovery routines. Return verified results or an
explicit decision for the user, and preserve those properties as concurrent work grows.
The [reliable-change roadmap](RELIABLE-CHANGE-ROADMAP.md) is the source of Goal
acceptance criteria, dependencies, current gaps and evidence requirements.
[constitution.xml](constitution.xml) remains the product/development contract.

| Delivery boundary | User-visible capability | Planning reference |
| --- | --- | --- |
| Outcome and measurement | See verified results, failures and missing evidence per request | G1 |
| Bounded recovery | Resume the remaining steps of a fixed two-step change after interruption | G2 |
| Ownership and provider continuity | Continue the same change across an agent/provider handoff | G3 |
| Measured scale-out | Increase verified throughput while preserving conflict and recovery correctness | G4 |
| Whole-product acceptance | Internal routines carry the initial request through review, repair and recovery; installed UI exposes the resulting evidence | G5, integrating G1–G4 |

These are delivery boundaries, not five assigned release numbers. A release
number is assigned only when scope and acceptance evidence are ready. A merged
PR or compiled binary does not by itself satisfy a product Goal.

G5 is the umbrella acceptance, not a final UI packaging milestone. Its harness may
submit the initial request, inject declared faults and observe. External creation
or assignment of subsequent tasks, repair instructions or resume messages cannot
substitute for the internal loop in a passing run. Explicit user decisions remain
visible and recorded; internal routines continue after the response.

The first implementation slice makes Task rejection delivery durable: store the
verdict and delivery obligation atomically, then resume pending delivery at boot
or through internal retries. Delivery proof alone is not repair success or G5
completion. The existing G1 JSON contract and activated measurement Goal/Task keep
their scope; this slice does not close them.

## Release rules

- Every minor release names its user-visible capability promise.
- Keep the product pre-1.0 until repository collaboration, release truth and the
  core operator path are trustworthy with evidence. This roadmap does not declare 1.0 readiness.
- Existing v2 tags remain historical; do not publish new v2 releases. Release
  automation compares versions within the active major series. Keep the current
  release-train guard and `scripts/bump-version.sh` policy in force.
- Patch releases repair the current train; public MCP capability expansion belongs
  in a minor or major release.
- Keep product SemVer (`dune-project`), protocol version and artifact schemas
  separate. This roadmap does not bump any of them.
- Source, CI, installed binary, live destination result and UI proof have separate
  statuses. A release claim links the applicable evidence at the shipped revision.
- Existing Goal ownership and contracts are preserved. Reuse their evidence only
  where its source/runtime/workload matches the new acceptance scope.
- Runtime budgets and arbitrary agent counts are not substitutes for verified
  work. Measurements guide development decisions, not lifetime expiry for tasks.

## Supporting planning

[IMMORTAL-SERVER-ROADMAP.md](IMMORTAL-SERVER-ROADMAP.md) concerns server supervision
and HA. Server restart alone does not establish recovery of an interrupted
business effect or composition node. Prioritize that work where a named Goal's
failure evidence requires it.

Issue intake continues to use `.github/issue-taxonomy.json` and the repository's
typed issue forms. Work is decomposed into independently reviewable tasks and
PRs; the linked product Goal provides the acceptance context.
