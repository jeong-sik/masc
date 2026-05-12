# Line-ref sweep cluster #4 — scattered singles symbol-anchored (8 specs); KeeperContextLifecycle picked up two relocations

**Date**: 2026-05-12 · **Iteration**: 85 (`/loop` FSM/TLA+/OCaml drift hunt) · **Phase**: R (line-ref sweep, cluster #4 — the last one)
**Specs touched**: `KeeperCascadeAttemptFSM.tla`, `KeeperCompactionLifecycle.tla`, `KeeperCompositeLifecycle.tla`, `KeeperContextLifecycle.tla`, `KeeperDecisionPipeline.tla`, `KeeperMemoryLifecycle.tla`, `KeeperSocialModelMagenticLedger.tla`, `KeeperStateMachine.tla` (8 specs, all comment-only)
**Verdict**: **~22 `<file>:<line>` citations across 8 specs converted to `<file> — <symbol>` form (iter 64 N-2.a).** Two of them weren't a simple line→symbol conversion — the cited symbol had *moved between files*: `is_input_overflow` (`keeper_unified_turn.ml:318`) is now `Keeper_error_classify.is_context_overflow` (the `TokenBudgetExceeded { kind = "Input"; _ } -> true` arm in `keeper_error_classify.ml`); the `keeper_social_model_magentic_ledger_v1.ml:204` ref's file was renamed/restructured into `keeper_social_model.ml` + `keeper_social_model_registry.ml` (the symbol `derive_failure_state` survives, in `keeper_social_model.ml`, dispatching to `Keeper_social_model_registry.derive_failure_state`). All model bodies byte-identical; TLC sanity-re-run on KeeperCascadeAttemptFSM (clean = no error, 65 states / 29 distinct; buggy = `SafetyInvariant` violated). `specs/INDEX.md` regenerated (8 content-hash bumps, no others).

## Why this cluster (line-ref sweep #4 — the last)

iter 81's corpus survey enumerated three big `\.ml:[0-9]` clusters (3-axis-type-def trio → iter 82 #14967; KeeperToolSurface ~16 hits → iter 83 #14968; KeeperPostTurnOrchestration ~9 hits → iter 84 #14971) plus a tail of "scattered singles" — 1-2 hits each across ~6 specs. This PR clears the scattered tail. After this PR + #14968 + #14971 all merge, the only `\.ml:[0-9]` left in `specs/keeper-state-machine/*.tla` is zero — at which point a `\.ml:[0-9]` zero-tolerance lint becomes a *house-clean guard* (iter 74 baseline-drain posture: the cleanup happens first, so the lint is not a "boost the string classifier" workaround — it just freezes a state already reached).

## What was converted (sub-class 8: line-reference drift)

| Spec | Old citation | New anchor | Note |
|---|---|---|---|
| KeeperCascadeAttemptFSM | `cascade_fsm.ml:7-12` | `cascade_fsm.ml — type provider_outcome` | `cascade_fsm.ml` is 138 LOC, stable; `type provider_outcome`@7 (exact). Preventive. |
| KeeperCascadeAttemptFSM | `cascade_fsm.ml:14-19` | `cascade_fsm.ml — type decision` | `type decision`@15 (+1). Preventive. |
| KeeperCascadeAttemptFSM | `cascade_fsm.ml:20` | `the Exhausted constructor of type decision in cascade_fsm.ml` | `Exhausted`@20 (exact). |
| KeeperCascadeAttemptFSM | `keeper_turn_driver.ml:657-669` / `:654-672` (×5: mapping row + lines 50, 53, 200, 225, 273) | `keeper_turn_driver.ml — the hard-quota fast-path in run_named (the `if sdk_error_is_hard_quota sdk_err then ... Cascade_fsm.Exhausted { last_err }` block, pinned by the "Hard-quota fast-path" comment)` | The branch is inside the ~930-LOC `run_named` body; actual position ~654-674 (≈ cited). Preventive. |
| KeeperCompactionLifecycle | `keeper_state_machine.ml:8/10/11/14` (×4) | `keeper_state_machine.ml — type phase, the Running / Overflowed / Compacting / Paused constructors` | Top-of-file `type phase`@6; line refs were *exact* (iter 81 survey flagged these as the stable case). Converted for consistency so the zero-tolerance lint can land. |
| KeeperDecisionPipeline | `keeper_composite_observer.ml:25-32` | `keeper_composite_observer.ml — type decision_stage re-export + all_decision_stages list` | `type decision_stage = Keeper_registry.decision_stage = ...`@22, list@28-33 (+~−3). |
| KeeperStateMachine | `keeper_state_machine.ml:754-758` (×2: ZombieIsForever, ZombieRequiresTerminalFailureLatched) | `keeper_state_machine.ml — apply_event's terminal-state reject arm (\| Stopped \| Dead \| Zombie -> ... Error (Terminal_state {...}))` | `apply_event`@1147 (drifted +~390 from line 754); the `:754-758` band now holds an `entry_actions_for` arm. |
| KeeperCompositeLifecycle | `keeper_post_turn.ml:45-232` | `keeper_post_turn.ml — the post-turn lifecycle orchestration (apply_post_turn_lifecycle_with_resilience_handles and the compaction/rollover/wirein steps it sequences)` | `:45-232` was a "the whole module's lifecycle block" range; the orchestration body is `apply_post_turn_lifecycle_with_resilience_handles`@361. |
| KeeperSocialModelMagenticLedger | `keeper_social_model_magentic_ledger_v1.ml:204` | `keeper_social_model.ml — derive_failure_state (dispatches to Keeper_social_model_registry.derive_failure_state)` | **File renamed/restructured**: `keeper_social_model_magentic_ledger_v1.ml` → `keeper_social_model.ml` + `keeper_social_model_registry.ml`. `derive_failure_state`@167 in `keeper_social_model.ml`. |
| KeeperContextLifecycle | `keeper_unified_turn.ml:318` (`is_input_overflow` pattern matcher) | `Keeper_error_classify.is_context_overflow (keeper_error_classify.ml — the Agent_sdk.Error.Agent (TokenBudgetExceeded { kind = "Input"; _ }) -> true arm), called from keeper_unified_turn.ml's per-turn retry loop (... when EC.is_context_overflow err -> branch)` | **Symbol relocated between files**: the `is_input_overflow` predicate no longer exists in `keeper_unified_turn.ml`; the input-token-overflow recognition is now `Keeper_error_classify.is_context_overflow`@673 (`keeper_error_classify.ml`). `keeper_unified_turn.ml` only *calls* it (via `EC.is_context_overflow`@1779/1804). |
| KeeperContextLifecycle | `keeper_state_machine.ml:402-408 Compaction_failed _ handler` | `keeper_state_machine.ml — update_conditions's \| Compaction_failed _ -> arm` | `update_conditions`@547, the `Compaction_failed _ ->` arm@598 (drifted +~190 as event variants were inserted above it). |
| KeeperMemoryLifecycle | (no live ref — line 16 *quoted* the old `keeper_memory_policy.ml:155-157` form inside the iter-81 convention-switch note) | reworded the note so it no longer contains a literal `:NNN` | Quoted-mention cleanup so the zero-tolerance lint won't false-positive on it. |

## The two relocations (worth flagging)

This cluster was the first line-ref sweep where the cited *symbol had moved between files*, not just drifted within a file:

1. **`is_input_overflow` → `Keeper_error_classify.is_context_overflow`** — the SDK-error classification predicate was extracted out of `keeper_unified_turn.ml` (3037 LOC) into a dedicated `keeper_error_classify.ml`. A bare line-number anchor would have pointed at unrelated code; a bare symbol anchor would have pointed at a non-existent symbol. The new anchor names both the current predicate (in `keeper_error_classify.ml`) and the call site (in `keeper_unified_turn.ml`).
2. **`keeper_social_model_magentic_ledger_v1.ml` → `keeper_social_model.ml` + `keeper_social_model_registry.ml`** — the `_v1` module was renamed and split. `derive_failure_state` survives in `keeper_social_model.ml` as a thin dispatcher to `Keeper_social_model_registry.derive_failure_state`.

This confirms the iter-81 drift-tracks-growth model has a *second axis*: not just "deep refs into growing files drift", but "refs into files that get refactored/renamed go fully stale". Symbol anchors survive intra-file growth; they need a re-point on rename/split — which is exactly when a spec audit catches it.

## Cross-checks (pass)

| Spec element | Runtime | Status |
|---|---|---|
| `provider_outcome` / `decision` / `Exhausted` | `cascade_fsm.ml` — `type provider_outcome`@7, `type decision`@15, `Exhausted`@20 | ✓ |
| hard-quota force-Exhausted branch | `keeper_turn_driver.ml`'s `run_named` — `if sdk_error_is_hard_quota sdk_err then ... Cascade_fsm.Exhausted { last_err }` (~@654-674, pinned by "Hard-quota fast-path" comment) | ✓ |
| `type phase` constructors | `keeper_state_machine.ml` — `type phase`@6 (`Running`@8, `Overflowed`@10, `Compacting`@11, `Paused`@14) | ✓ — exact |
| decision_stage exhaustiveness re-export | `keeper_composite_observer.ml` — `type decision_stage = Keeper_registry.decision_stage = ...`@22 + `all_decision_stages`@28-33 | ✓ |
| `apply_event` terminal-state reject | `keeper_state_machine.ml` — `apply_event`@1147, the `\| Stopped \| Dead \| Zombie -> ... Error (Terminal_state {...})` arm | ✓ |
| post-turn lifecycle atomicity | `keeper_post_turn.ml` — `apply_post_turn_lifecycle_with_resilience_handles`@361 (the orchestration body) | ✓ |
| failure-path event construction | `keeper_social_model.ml` — `derive_failure_state`@167 → `Keeper_social_model_registry.derive_failure_state` | ✓ |
| input-overflow recognition | `keeper_error_classify.ml` — `is_context_overflow`@673 (the `TokenBudgetExceeded { kind = "Input"; _ } -> true` arm); call site `keeper_unified_turn.ml`@1779/1804 (`EC.is_context_overflow err`) | ✓ |
| `Compaction_failed _` handler | `keeper_state_machine.ml` — `update_conditions`@547, the `\| Compaction_failed _ ->` arm@598 | ✓ |
| KeeperCascadeAttemptFSM `.cfg` / `-buggy.cfg` | both present | ✓ |
| Bug-Model contract (KCAF sanity) | clean = no error (65 states / 29 distinct); buggy = `SafetyInvariant` violated — re-verified this PR | ✓ |

The other 7 specs' model bodies are byte-identical to origin/main (`git diff` shows only comment lines changed) — no TLC re-run needed for those (honest-doc posture; KCAF re-run as the representative sanity).

## Sub-class placement & follow-up

- Drift = **sub-class 8 (line-reference drift)** — the "scattered singles" tail, plus the first instances of *cross-file symbol relocation* within the loop's line-ref work (`is_input_overflow`, `keeper_social_model_magentic_ledger_v1.ml`).
- **`\.ml:[0-9]` remaining in `specs/keeper-state-machine/*.tla` after this PR**: only `KeeperPostTurnOrchestration.tla` (9 hits — all converted in the *unmerged* iter 84 PR #14971) and `KeeperToolSurface.tla` (16 hits — all converted in the *unmerged* iter 83 PR #14968). Once #14968 + #14971 + this PR all merge, the count is **zero**. At that point the `\.ml:[0-9]` zero-tolerance lint can land as a house-clean guard. (It is *not* the `String.starts_with` / "boost the classifier" workaround — the cleanup is done first, the lint just freezes the cleaned state and stops new line-number anchors from accumulating. Distinct from a lint that *suppresses* a symptom while the underlying drift continues.)
- No follow-up PR owed for *this* spec set. Comment-only — model bodies byte-identical; `specs/INDEX.md` regenerated (8 content-hash bumps). All 8 specs are in the `make -C specs check-clean` runner; CI re-checks them.
