# 3-axis type-def line-ref sweep — symbol-anchor `keeper_registry.ml:63-81` across KeeperCascadeLifecycle / KeeperDecisionPipeline / KeeperTurnCycle (iter 82)

**Date**: 2026-05-12 · **Iteration**: 82 (`/loop` FSM/TLA+/OCaml drift hunt) · **Phase**: R (line-ref sweep, cluster #1)
**Specs**: `KeeperCascadeLifecycle.tla` (303 LOC) · `KeeperDecisionPipeline.tla` (267 LOC) · `KeeperTurnCycle.tla` (418 LOC)
**OCaml**: `lib/keeper/keeper_registry.ml` — `type turn_phase` / `type decision_stage` / `type cascade_state` (the 3-axis turn FSM) + `module Turn_phase_transition` (the GADT)
**Verdict**: **3 specs, 10 shared/related line-ref citations, all stale (drift +103 to +556), symbol-anchored comment-only**. All three specs reference the same three type definitions in `keeper_registry.ml` for their 3-axis state mapping, and all three used the *original* line ranges `:63-68` / `:70-74` / `:76-81` — which now point into an unrelated `terminal_reason` variant block. The type defs have moved as `keeper_registry.ml` grew. Models unchanged; TLC re-verified one spec (KeeperDecisionPipeline: clean = no error, buggy = `DecisionBoundaryRequiresMeasurement` violated).

## Why this cluster (line-ref sweep #1)

iter 81's corpus survey (`docs/tla-audit/kml-r8-...md`) identified the biggest remaining `\.ml:[0-9]` clusters: KeeperToolSurface (~15 hits, `keeper_run_tools.ml:NNN`) and the `keeper_registry.ml:63-81` 3-axis-type-def trio (3 specs sharing the same 3 refs). This PR takes the trio — it's the highest-leverage single fix (3 specs, one root cause: the 3-axis type defs moved).

## What drifted (sub-class 8: line-reference drift)

| Spec citation (in all 3 specs) | Actual location in `keeper_registry.ml` 2026-05-12 | Drift | Fix |
|---|---|---|---|
| `keeper_registry.ml:63-68` — `type turn_phase = Turn_idle \| ...` | `type turn_phase` at line **166** | **+103** | `keeper_registry.ml — type turn_phase` |
| `keeper_registry.ml:70-74` — `type decision_stage = Decision_undecided \| ...` | `type decision_stage` at line **504** | **+434** | `keeper_registry.ml — type decision_stage` |
| `keeper_registry.ml:76-81` — `type cascade_state = Cascade_idle \| ...` | `type cascade_state` at line **632** | **+556** | `keeper_registry.ml — type cascade_state` |
| `keeper_registry.ml:234-244` — "declares 7 GADT transitions" (KeeperTurnCycle only) | the GADT `module Turn_phase_transition` (`type ('from, 'to_) t = ...`) is at ~line **243-246**; the RFC-0072-Phase-4 comment block above it at ~234 | ~0..+2 (roughly accurate, but a line range that can rot) | `keeper_registry.ml`'s `module Turn_phase_transition` (GADT-encoded turn_phase transitions) — symbol anchor; also softened "declares 7 GADT transitions" → "declares the cross-state transitions" (the OCaml comment there actually says "19 [valid pairs]" of the "7-variant [turn_phase] FSM" — the "7" in the spec was a description nit; left a precise count out rather than guess) |

What lines 63-81 actually contain now: a `terminal_reason` variant block (`Stale_fleet_batch`, `Oas_timeout_budget_loop`, `Provider_runtime_error`, ...) — entirely unrelated to the 3-axis types. Confirmed stale.

## Cross-checks (pass)

| Spec element | Runtime | Status |
|---|---|---|
| `turn_phase` axis (`Turn_idle` / `Turn_prompting` / ...) | `type turn_phase` in `keeper_registry.ml` (now line 166) | ✓ — symbol anchor accurate |
| `decision_stage` axis (`Decision_undecided` / ...) | `type decision_stage` (now line 504) | ✓ |
| `cascade_state` axis (`Cascade_idle` / ...) | `type cascade_state` (now line 632) | ✓ |
| turn_phase GADT transitions (KeeperTurnCycle) | `module Turn_phase_transition` (RFC-0072 Phase 4, GADT, ~line 243) | ✓ — symbol anchor; the RFC-0072 transition matrix is the active spec for that axis (iter 38-41 work) |
| `.cfg` / `-buggy.cfg` (all 3) | present | ✓ |
| Bug-Model contract (sampled: KeeperDecisionPipeline) | clean = no error; buggy = `DecisionBoundaryRequiresMeasurement` violated — re-verified this PR | ✓ |

## Sub-class placement & follow-up

- Drift = **sub-class 8 (line-reference drift)** — and a *shared-root-cause* instance: one set of type-def moves invalidated citations in three specs at once, because they all map the same 3-axis FSM. Converting all three to symbol anchors in one PR is the right granularity.
- **Remaining `\.ml:[0-9]` clusters** (from iter 81's survey, still open): KeeperToolSurface (`keeper_run_tools.ml:NNN`, ~15 hits, the biggest single-spec cluster — next sweep candidate), KeeperPostTurnOrchestration (`keeper_post_turn.ml:NNN`, ~8 hits), plus scattered singles (`keeper_unified_turn.ml:318/1640`, `keeper_state_machine.ml:402-408/754-758`, `keeper_social_model_magentic_ledger_v1.ml:204`, `keeper_composite_observer.ml:25-32`). Once those are converted, a `\.ml:[0-9]` zero-tolerance lint becomes a *house-clean guard* (not a "boost the classifier" workaround — same posture as the iter 74 OCaml-docstring baseline drain).
- No follow-up PR owed for *these* specs. Comment-only changes — model bodies byte-identical; `specs/INDEX.md` regenerated (3 content-hash bumps). All three specs are in the `make -C specs check-clean` runner; CI re-checks them.
- Description nit flagged but not fixed (out of scope): KeeperTurnCycle's "7 GADT transitions" — the OCaml says "19 valid pairs of the 7-variant turn_phase FSM"; the "7" should probably be "19 transitions" or "the 7-variant FSM's transitions". Softened to "declares the cross-state transitions" here; a precise re-count is a separate small finding.
