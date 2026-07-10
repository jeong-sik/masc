# RFC-0337 — Evidence Gate Semantics SSOT (rev 2)

- **Status:** Draft
- **Authors:** Vincent (yousleepwhen)
- **Created:** 2026-07-10 (rev 2: same day, after structural review on PR #23888)
- **Related:** RFC-0311 (L1 evidence gate, Phase 1), RFC-0109 (Phase D hard cut), RFC-0323 (verification matrix; G-2, G-5), #23886 (thrash-chain radius), #23775 (Anti Gate 0 scoping)
- **Supersedes:** per-PR gate semantics improvisation across #23666/#23738/#23750/#23840/#23881/#23882; rev 1 of this document (which misstated live topology)

## TL;DR

Completion evidence has one deterministic owner — `Task_completion_gate.decide` (L1) — and one LLM
reviewer — `Anti_rationalization.review` (L2). L2's duplicate deterministic Gate 0 is removed after
#23775 lands. Advisory tasks keep the L1 trusted-ref requirement (RFC-0311 tripwire preserved);
`strict` adds contract-specified evidence and LLM verification. Callers thread evidence end to end
and never hardcode `[]`. Gate-region changes cite this RFC.

## Live topology (measured, current main)

Rev 1 claimed a single gate site; live code has **three** evidence checks on the completion path:

| # | Site | Kind | Scope today |
|---|---|---|---|
| 1 | `workspace_task_transitions.ml:91-114` strict precheck | deterministic | scoped by `task_requires_verification` |
| 2 | `Task_completion_gate.decide` via `Workspace_hooks.task_completion_gate_decide_fn` (`tool_task.ml:459-498`) | deterministic, trust-validating | **unscoped** — every `Done_action`/`Submit_for_verification`, rejects unless a trusted ref is present (RFC-0311 Phase 1) |
| 3 | `Anti_rationalization.review` Gate 0 (`tool_task.ml:416-436` → `review_completion_notes`) | deterministic pre-check inside the LLM reviewer | runs only on `Done_action && not force`; scoped by `~requires_evidence` after #23775 |

Consequences rev 1 missed: (a) #2 subsumes #3 — anything Gate 0 rejects (empty refs), `decide`
also rejects (empty ⇒ no trusted ref), so #23775 alone changes the rejection's *source*, not the
*outcome*; (b) the Anti reviewer never sees `Submit_for_verification` or `force=true` completions.

## The policy fork (decided here)

The thrash chain was fueled by an unresolved conflict between two RFC lineages:

- **RFC-0311/0109:** every completion needs one trusted, reviewer-inspectable evidence ref —
  notes alone never complete a task (fake-done tripwire, pinned by
  `test_task_completion_gate.ml` on contract-less tasks).
- **RFC-0323 Phase A:** verification is a `strict` opt-in; advisory tasks must not be blocked by
  verification machinery.

**Decision: tiered evidence.** These do not actually conflict once "evidence" and "verification"
are separated:

| Task kind | L1 `decide` (deterministic) | L2 LLM review | Verification FSM |
|---|---|---|---|
| advisory (default) | **one trusted ref required** (RFC-0311 preserved) | length/quality gates only — no evidence re-check | not entered |
| `strict` | one trusted ref required | full review incl. contract evidence obligations | entered per RFC-0323 |

Rationale: dropping the L1 trusted-ref requirement for advisory tasks would reopen fleet-wide
fake-done (advisory is the fleet default; "see notes" would complete tasks again). The #23738
complaint is resolved not by unscoping L1 but by removing the *duplicate* L2 deterministic reject
(#23775) and by keeping L1's failure payload actionable (`handoff_context.evidence_refs` named,
`rule_id` stable).

## Decisions

1. **L1 owner.** `Task_completion_gate.decide` is the only deterministic evidence decision. It
   stays unscoped across advisory/strict (one trusted ref for everyone), fail-closed on a missing
   task. RFC-0311 remains in force; this RFC does not supersede it.
2. **L2 owner.** `Anti_rationalization.review` owns LLM-judged completion quality. Its Gate 0
   (deterministic empty-evidence reject) is redundant with L1 and is **removed** once #23775's
   scoping lands (removal is a follow-up PR citing this RFC; `if false &&` dead-code disables
   remain forbidden — delete, don't disable).
3. **Action scope.** L1 runs on `Done_action` and `Submit_for_verification`, never on
   claim/start/cancel/release/approve/reject transitions (already encoded in `needs_gate`,
   `tool_task.ml:461-474`). L2 runs on `Done_action && not force`; `force=true` still passes L1
   (evidence is a safety invariant, not a business rule — comment at `tool_task.ml:455-458`).
4. **Evidence threading.** `masc_transition` threads `handoff_context.evidence_refs`;
   `keeper_task_done` parses refs at the API boundary (`parse_keeper_task_done_evidence_refs`) and
   maps typed claims to display strings for the review request. A hardcoded `[]` at any call site
   is the #23666 defect class and is rejected on review. Boundary schemas should declare
   `minItems: 1` and item `minLength: 1` where the field is required (gap: `masc_transition`
   schema today trims/drops silently — follow-up).
5. **Failure semantics.** L1 rejects with stable `rule_id` + payload naming
   `handoff_context.evidence_refs`; L2 rejects surface as `Workflow_rejection`. Gates are never
   silent, never demoted to logs, never disabled via dead code. If a gate is wrong, revert it or
   amend this RFC — those are the only two moves.
6. **Change control.** Any PR touching the gate region (`task_completion_gate.ml`,
   `anti_rationalization.ml` gates, the `needs_gate`/`review_gate_rejection` blocks in
   `tool_task.ml`, `workspace_task_transitions.ml` precheck) cites this RFC in its body.
   Gate-behavior changes without an RFC amendment are rejected on review.

## Migration

1. #23775 (Anti Gate 0 `~requires_evidence` scoping) lands as-is — its effect is removing the L2
   duplicate reject; its body should stop claiming it unblocks advisory completions (L1 still
   requires one trusted ref for them, by design).
2. Follow-up PR deletes Anti Gate 0 entirely (decision 2), citing this RFC.
3. Follow-up PR fixes the `tool_task.ml` comment "Analysis-only tasks (no contract) bypass the
   gate" — false today (decide has no such bypass) and false under this RFC (advisory tasks are
   not bypassed; they need one trusted ref).
4. Follow-up PR adds `minItems`/`minLength` to boundary schemas (decision 4 gap).

## Non-goals

- **Evidence validity beyond trust-shape.** Fabrication detection and snapshot digests are the
  board claim gate / RFC-0323 Phase-A territory.
- **Verification default-on rollout.** `MASC_VERIFICATION_DEFAULT_ON` staging is RFC-0323 G-5.
