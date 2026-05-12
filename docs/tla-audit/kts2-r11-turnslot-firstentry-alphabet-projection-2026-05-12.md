# KTS2 R-11 — KeeperTurnSlot.tla: first-entry audit — model clean; mapping table was silent about the `ReleasePhaseSet` alphabet projection (sub-class 1, mild)

**Date**: 2026-05-12 · **Iteration**: 86 (`/loop` FSM/TLA+/OCaml drift hunt) · **Phase**: R (first-entry audit of a previously-unaudited spec)
**Spec**: `specs/keeper-state-machine/KeeperTurnSlot.tla` (244 LOC including preamble/comments, bug-model paired) — #12888 productive-slot lifecycle contract
**OCaml**: `keeper_turn_cascade_budget.ml` (the degraded-retry classifier — `Degraded_retry_allowed` / `Degraded_retry_slot_phase_exhausted` branches), `keeper_unified_turn.ml` (`current_turn_phase_elapsed_ms ()` closure in the turn loop), `keeper_execution_receipt.ml` (`type slot_release_phase`, `type cascade_rotation_attempt` with `slot_release_at_phase : slot_release_phase option`), `env_config_keeper.ml` (`KeeperRetryBackoff.degraded_retry_slot_phase_budget_sec`)
**Verdict**: **Model body clean and accurate; the spec was already symbol-anchored (no line refs); bug-model is well-formed. One mapping-table gap fixed comment-only: the table didn't disclose that `ReleasePhaseSet` is a *projection* of the runtime's `slot_release_phase` alphabet, not a 1:1 image — and three citations were tightened (the `current_turn_phase_elapsed_ms` closure, which had been cited as if module-level; the `Degraded_retry_allowed` / `Degraded_retry_slot_phase_exhausted` classifier branches, which hadn't named `keeper_turn_cascade_budget.ml`; the `slot_release_phase` receipt field, now pointed at `keeper_execution_receipt.ml`).** Model body byte-identical; TLC re-verified (clean = no error, 69 states / 59 distinct; buggy `RetryScheduledWithoutRelease` → `RetryPhaseRequiresReleased` violated).

## Why this spec

iter 81's survey + iter 85's wrap-up left a tail of ~5 never-first-entry-audited specs (KeeperTurnSlot, OperatorPauseBroadcast, …). KeeperTurnSlot is the formal target for the 174s↔600s slot-leak class (#12888) — a good first-entry pick: small, bug-model paired, and the kind of spec where an alphabet mismatch would matter (it's a leak invariant on a release-phase enum).

## What was checked

| Spec element | Runtime | Status |
|---|---|---|
| `ProductivePhaseBudget` | `Env_config_keeper.KeeperRetryBackoff.degraded_retry_slot_phase_budget_sec` (`env_config_keeper.ml` — `KeeperRetryBackoff` module, `degraded_retry_slot_phase_budget_sec` value) | ✓ exists |
| `productive_elapsed` | `current_turn_phase_elapsed_ms ()` — a *closure* inside `keeper_unified_turn.ml`'s turn loop (not a module-level binding) | ✓ exists — citation tightened to say "closure" |
| `RetryScheduled` action | the `Degraded_retry_allowed _` branch of `keeper_turn_cascade_budget.ml`'s degraded-retry classifier | ✓ exists — citation tightened to name the file/classifier |
| `ProductivePhaseExhausted` action | the `Degraded_retry_slot_phase_exhausted _` branch of the same classifier | ✓ exists — same |
| `release_at_phase` | `cascade_rotation_attempt.slot_release_at_phase : slot_release_phase option` in `keeper_execution_receipt.ml` | ✓ exists, correct field name |
| `.cfg` / `-buggy.cfg` | both present | ✓ |
| Bug-Model contract | clean = no error (69 states, 59 distinct); buggy = `RetryPhaseRequiresReleased` violated (via `RetryScheduledWithoutRelease`) — re-verified this PR | ✓ — well-formed (the buggy action models "degraded retry changes the logical phase but keeps the slot", exactly the leak it pins) |
| line-ref drift | none — spec already cites OCaml by symbol name | ✓ |

## The gap (sub-class 1: coverage gap — mild, *disclosure-only*)

The spec's `ReleasePhaseSet == {"none", "retry_scheduled", "productive_phase_exhausted", "finish"}` (4 values) is **not a 1:1 image** of the runtime's release-phase alphabet:

- Runtime: `type slot_release_phase` (`keeper_execution_receipt.ml`) — 4 *non-None* constructors: `Retry_setup_failed`, `Retry_scheduled`, `Retry_budget_exhausted`, `Productive_phase_exhausted`; plus the `option` wrapper (`None` when no rotation occurred).
- Spec keeps `retry_scheduled` ↔ `Retry_scheduled` and `productive_phase_exhausted` ↔ `Productive_phase_exhausted` (the two slot-release outcomes the leak invariant cares about), **drops** `retry_setup_failed` / `retry_budget_exhausted` (other terminal rotation outcomes — they also release the slot, but aren't on the leak path this spec pins), and **adds** two spec-internal markers: `none` (↔ the `option` `None` / no rotation) and `finish` (a clean productive-phase finish releases the slot — the runtime records *no* `slot_release_phase` for that case, since `slot_release_at_phase` only exists on `cascade_rotation_attempt`, which is only constructed for degraded retries).

So the spec is a *leak-relevant projection* of the runtime alphabet, plus the no-rotation / clean-finish endpoints needed to make the model a closed FSM. That's a legitimate modeling choice — but the original mapping table cited `cascade_rotation_attempt.slot_release_at_phase` as the counterpart of `release_at_phase` with no hint that the alphabets differ. A future maintainer adding `Retry_setup_failed` handling, or seeing the spec's `finish` and looking for a `Finish` constructor, would be misled.

**Fix (comment-only)**: added an "Alphabet projection (spec scope)" block to the preamble naming the runtime type (`slot_release_phase` in `keeper_execution_receipt.ml`), enumerating its 4 constructors, and explaining which two the spec keeps, which two it drops and why, and that `none`/`finish` are spec-internal endpoints (not runtime constructors). Also tightened the three vague citations (closure, file-named classifier branches, `keeper_execution_receipt.ml` for the receipt field) and added the iter-64 N-2.a header note.

This is the same shape as the `PhaseSet` projection disclosures added in iter 78 (KCGP, 2-phase), iter 79 (KOC), iter 80 (KLP, 3-phase) — a spec that *correctly* models a projection of a runtime enum but doesn't *say so* in the mapping table.

## Sub-class placement & follow-up

- Drift = **sub-class 1 (coverage gap), mild form** — the model is clean; only the mapping documentation under-disclosed the alphabet projection. Comment-only fix.
- No follow-up PR owed. Comment-only — model body byte-identical; `specs/INDEX.md` regenerated (KeeperTurnSlot content-hash bump `f75c324a95fe` → `6c970f9002bd`). The spec is in the `make -C specs check-clean` runner; CI re-checks it.
- **Remaining never-first-entry-audited specs**: OperatorPauseBroadcast (135 LOC), and a few others (KeeperEventQueue / KeeperHeartbeat / KeeperWorkPipeline / KeeperTaskAcquisition / KeeperApprovalQueue depending on how "audited" is counted — several have had partial entries in earlier iterations). Next first-entry candidate: OperatorPauseBroadcast.
- This is *not* an RFC-gated subsystem (KeeperTurnSlot models the turn-slot lifecycle, not credential/keeper_gh/host_config, not repo_manager, not operator_control credential handlers, not keeper_sandbox/shell, not dashboard credential component, not .claude/hooks, not instructions/workflow). RFC-WAIVED.
