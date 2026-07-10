# RFC-0337 — Evidence Gate (Gate 0) Semantics SSOT

- **Status:** Draft
- **Authors:** Vincent (yousleepwhen)
- **Created:** 2026-07-10
- **Related:** RFC-0323 (verification matrix; G-2 workspace gate, G-5 default-on flag), #23886 (thrash-chain radius analysis), #23775 (scoping repair)
- **Supersedes:** per-PR gate semantics improvisation across #23666/#23738/#23750/#23840/#23881/#23882

## TL;DR

The empty-evidence reject has exactly one home (`Anti_rationalization.review`, Gate 0), one scoping
predicate (`Masc_domain.task_requires_verification`), one action scope (completion-path actions only),
and one failure shape (`Workflow_rejection`, named field). Callers thread evidence; they never
hardcode `[]` and never pre-empt or disable the gate. Gate-region changes cite this RFC.

## Why

Between 2026-07-09 and 07-10, seven PRs pulled Gate 0 in opposing directions (full chain: #23886).
Two merged (#23666 introduced the gate with an unwired `[]` call site; #23738 wired evidence and
re-enabled it), five were closed unmerged after adversarial review: a done-action duplicate (#23750),
a second entry point (#23840), an action-unscoped clone that would have rejected every
`masc_transition` (#23881), and a `if false &&` dead-code disable resting on a premise #23738 had
already fixed (#23882). The root cause is not any single PR: the gate's semantics were never
specified, so each keeper inferred a different contract and shipped it.

## Decision

1. **Single gate site.** The policy decision "is empty evidence acceptable for this task" is made
   only in `Anti_rationalization.review` (verdict gate `Evidence`). Tool boundaries
   (`tool_task.ml`, `keeper_tool_task_runtime.ml`) keep argument-shape validation only — when
   `evidence_refs` is provided it must be a non-empty array of non-empty strings — and never make
   the policy call. No pre-checks, no second gates.
2. **Single scoping predicate.** `Masc_domain.task_requires_verification` decides which tasks the
   gate applies to, threaded into `review` as `~requires_evidence` (#23775). The same predicate
   drives the RFC-0323 G-2 workspace gate; the two must never diverge. Analysis-only and
   advisory-contract tasks complete without evidence.
3. **Action scope.** The gate evaluates only on completion-path actions (`Done_action`,
   `Submit_for_verification`). It never runs on claim/release/block/todo transitions. A transition
   that carries no `handoff_context` and is not a completion is not the gate's business.
4. **Evidence sources.** `masc_transition` threads `handoff_context.evidence_refs`;
   `keeper_task_done` threads typed claims rendered via `Evidence_claim.to_human_string`. Call
   sites must thread the field end to end; a hardcoded `[]` at any call site is the #23666 defect
   class and is rejected on review.
5. **Failure semantics.** A gate reject is a `Reject` verdict surfaced as
   `Tool_result.Workflow_rejection` whose message names the missing field. The gate is never
   silent, never demoted to a log line, and never disabled via dead code (`if false && …`). If the
   gate is wrong, revert the commit that made it wrong or amend this RFC — those are the only two
   moves.
6. **Change control.** Any PR touching the gate region (`anti_rationalization.ml` Gate 0,
   `tool_task_handlers.ml` review call, the `~requires_evidence` threading) cites this RFC in its
   body. Gate-behavior changes without an RFC amendment are rejected on review, per the workspace
   workaround-rejection bar.

## Non-goals

- **Evidence validity.** Whether a cited ref is real (fabrication detection, snapshot digests) is
  the board claim gate and RFC-0323 Phase-A territory, not Gate 0.
- **Verification default-on rollout.** `MASC_VERIFICATION_DEFAULT_ON` staging is RFC-0323 G-5.

## Migration

#23775 lands the `~requires_evidence` scoping and is the only open gate PR; it becomes the first
implementation of this RFC. The closed thrash PRs are historical context, enumerated in #23886, and
stay closed.
