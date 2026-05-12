# KPTO R-10 — KeeperPostTurnOrchestration.tla: `keeper_post_turn.ml` refs symbol-anchored (still accurate, preventive); `keeper_unified_turn.ml:1640` drifted (fixed) — line-ref sweep cluster #3

**Date**: 2026-05-12 · **Iteration**: 84 (`/loop` FSM/TLA+/OCaml drift hunt) · **Phase**: R (line-ref sweep, cluster #3)
**Spec**: `specs/keeper-state-machine/KeeperPostTurnOrchestration.tla` (401 LOC, bug-model paired)
**OCaml**: `lib/keeper/keeper_post_turn.ml` — `apply_post_turn_lifecycle_with_resilience_handles` (the post-turn lifecycle body the spec models) · `lib/keeper/keeper_unified_turn.ml` — the `current_turn_blocker_info` stamp
**Verdict**: **9 line-ref citations symbol-anchored; the ~8 `keeper_post_turn.ml:NNN` ones (lines 600-656) were still roughly accurate but converted preventively, the 1 `keeper_unified_turn.ml:1640` had genuinely drifted (the stamp site is near line 1810, the ref-decl near 789), and the enclosing-function name in the `phase` row was slightly wrong (`apply_post_turn_lifecycle` → `apply_post_turn_lifecycle_with_resilience_handles`).** Model body unchanged; TLC re-verified (clean = no error, depth 11; buggy = `SafetyInvariant` violated).

## Why this cluster (line-ref sweep #3, the last big one)

iter 81's corpus survey flagged KeeperPostTurnOrchestration as the third cluster (~8-9 hits, mostly `keeper_post_turn.ml:NNN`). With this PR, all three big clusters (3-axis-type-def trio iter 82, KeeperToolSurface iter 83, KeeperPostTurnOrchestration iter 84) are converted; only scattered singles remain.

## What was checked / fixed (sub-class 8: line-reference drift — *and a confirmation of the drift-tracks-growth pattern*)

| Spec citation | Actual 2026-05-12 | Drift | Action |
|---|---|---|---|
| `keeper_post_turn.ml:600-656` — `phase` row ("control-flow position inside apply_post_turn_lifecycle") | the post-compaction → rollover → wirein-chain tail of `apply_post_turn_lifecycle_with_resilience_handles` (function @361, tail @~595-656); `apply_post_turn_lifecycle` itself (@658) is a 5-line wrapper | ~0 (line band still right) but the *function name* was wrong | → `keeper_post_turn.ml — apply_post_turn_lifecycle_with_resilience_handles (post-compaction → rollover → wirein-chain tail)`; semantic column corrected to name the real function |
| `keeper_post_turn.ml:622-632` — `compaction_decision` | the `compaction = { attempted; applied; failure_reason; trigger; ... }` record @~625-637 | ~0..+5 | → symbol anchor (the record construction in `apply_post_turn_lifecycle_with_resilience_handles`) |
| `keeper_post_turn.ml:600-608` — `rollover_decision` (×2, incl. inline at line 187) | `Keeper_rollover.maybe_rollover_oas_handoff` call @601 | ~0 | → symbol anchor |
| `keeper_post_turn.ml:648-656` — `wirein_order` (×3: mapping row + lines 80, 295) | the `apply_*_wirein` chain (`apply_autonomous_wirein`@648 → `apply_resilience_wirein` → `apply_tool_emission_wirein` → `apply_multimodal_wirein`@656) | ~0 (exact) | → symbol anchor (the chain) |
| `keeper_post_turn.ml:640-647` — "Do not reorder" comment (line 369) | the `(* Strict ordering: ... Do not reorder ... *)` comment @~639-647 | ~0 | → symbol anchor (the comment above the chain) |
| `keeper_unified_turn.ml:1640` — `blocker_klass` ↔ `current_turn_blocker_info.klass` | `keeper_unified_turn.ml` is ~3037 LOC; `current_turn_blocker_info` is a `ref None` declared @789, *set* via `current_turn_blocker_info := Some { klass = Sdk_token_budget_exceeded; detail = ... }` @~1810. Line 1640 is neither. | **drifted** (stamp +170 from line 1640, or the ref-decl -851) | → `keeper_unified_turn.ml — the \`current_turn_blocker_info := Some { klass; detail }\` stamp (the typed blocker_info written for the rollover gate; the ref is declared earlier in the same turn loop)` |

**The pattern, confirmed**: `keeper_post_turn.ml` is ~920 LOC and the cited region (lines 600-656) sits near the end of a function (`apply_post_turn_lifecycle_with_resilience_handles`, @361-656) — and since not much has been inserted *between* line 600 and the end of that function, those refs are still right. `keeper_unified_turn.ml` is ~3037 LOC and the `current_turn_blocker_info` stamp is buried deep in the turn loop — and *that* ref drifted +170. Same conclusion as iter 81's survey: drift magnitude tracks file growth and the cited symbol's depth. Converting the `keeper_post_turn.ml` refs anyway is preventive (when `keeper_post_turn.ml` next grows above line 600, they'd drift; symbol anchors won't).

## Cross-checks (pass)

| Spec element | Runtime | Status |
|---|---|---|
| post-turn lifecycle (compaction decision → rollover gate → wirein chain) | `apply_post_turn_lifecycle_with_resilience_handles` in `keeper_post_turn.ml` (@361, tail @595-656) | ✓ — symbol anchors accurate |
| `wirein_order` (canonical: autonomous → resilience → tool-emission → multimodal) | `apply_autonomous_wirein`@648 → `apply_resilience_wirein` → `apply_tool_emission_wirein` → `apply_multimodal_wirein`@656; pinned by the "Strict ordering ... Do not reorder" comment @~639-647 | ✓ |
| `rollover_decision` ← rollover gate | `Keeper_rollover.maybe_rollover_oas_handoff` call @601 (consumes `KeeperRolloverDecision.tla`'s outcome class — cross-spec, iter 75 KRD R-2) | ✓ |
| `blocker_klass` ← typed blocker_info | `current_turn_blocker_info := Some { klass; detail }` in `keeper_unified_turn.ml` (~@1810); `klass : blocker_class` field of `type blocker_info` in `keeper_meta_contract.ml`@243 (the `keeper_meta_contract.ml:blocker_info` row was already symbol-anchored & accurate) | ✓ |
| `.cfg` / `-buggy.cfg` | both present | ✓ |
| Bug-Model contract | clean = no error (state graph depth 11); buggy = `SafetyInvariant` violated — re-verified this PR | ✓ |

## Sub-class placement & follow-up

- Drift = **sub-class 8 (line-reference drift)** — but a *mixed* instance: one genuinely-drifted ref (`keeper_unified_turn.ml:1640`, big file) + several still-accurate-but-preventively-converted refs (`keeper_post_turn.ml:NNN`, small file) + a function-name nit. Useful confirmation of the iter-81 drift-tracks-growth model.
- **Remaining `\.ml:[0-9]` refs after this PR** (all "scattered singles" — 1-2 hits each, no big clusters left): `KeeperContextLifecycle.tla` (`keeper_unified_turn.ml:318`, `keeper_state_machine.ml:402-408`), `KeeperCompositeLifecycle.tla` (`keeper_post_turn.ml:45-232`), `KeeperCascadeAttemptFSM.tla` (`cascade_fsm.ml:7-12/14-19/20`, `keeper_turn_driver.ml:654-672/657-669` ×several), `KeeperSocialModelMagenticLedger.tla` (`keeper_social_model_magentic_ledger_v1.ml:204`), `KeeperStateMachine.tla` (`keeper_state_machine.ml:754-758` ×2), `KeeperDecisionPipeline.tla` (`keeper_composite_observer.ml:25-32`). One PR can clear these; then `\.ml:[0-9]` zero-tolerance lint becomes a house-clean guard (iter 74 baseline-drain posture — not a "boost the classifier" workaround, because the cleanup happens first).
- Comment-only — model body byte-identical; `specs/INDEX.md` regenerated. Content-hash: `0c26d77292b4` → `dea4d1f13ac5` (#14971) → `70d3db08a758` (the symbol-anchor follow-up that converted the remaining prose-form `keeper_post_turn.ml — …` refs in the preamble/body to `path.ml:symbol` anchors, softened the table header for the one control-flow-position row, and fixed the `keeper_meta_contract.ml::blocker_info` double-colon typo above). The spec is in the `make -C specs check-clean` runner; CI re-checks it.
