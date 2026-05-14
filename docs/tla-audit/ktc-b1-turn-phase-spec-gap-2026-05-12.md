# KTC Phase B-1 Audit — 3-Axis State Cross-Check

**Iteration**: 19 (/loop FSM/TLA+/OCaml drift hunt — first KTC entry)
**Date**: 2026-05-12
**Spec**: `specs/keeper-state-machine/KeeperTurnCycle.tla` (373 LOC)
**OCaml**: `lib/keeper/keeper_registry.ml` (`turn_phase` / `decision_stage` / `cascade_state` types)
**Risk**: MID — 2 active OCaml phases not modeled in spec; 7 invariants currently exclude these phases by silent omission.
**Type**: Audit-only (no code change in this PR).

## 3-axis cross-check matrix

| Axis | Spec set | OCaml variants | Aligned? |
|---|---|---|---|
| `turn_phase` (`TurnPhaseSet` §110) | 5: idle, prompting, executing, compacting, finalizing | 7: Turn_idle, Turn_prompting, **Turn_routing**, Turn_executing, Turn_compacting, Turn_finalizing, **Turn_exhausted** | ❌ **2 phases missing in spec** |
| `decision_stage` (`DecisionSet` §111) | 4: undecided, guard_ok, gate_rejected, tool_policy_selected | 4: Decision_undecided, Decision_guard_ok, Decision_gate_rejected, Decision_tool_policy_selected | ✅ Aligned |
| `cascade_state` (`CascadeSet` §112) | 5: idle, selecting, trying, done, exhausted | 5: Cascade_idle, Cascade_selecting, Cascade_trying, Cascade_done, Cascade_exhausted | ✅ Aligned |

## Drift detail — `turn_phase`

OCaml has two phases TLA+ doesn't model:

### `Turn_routing` (`[@tla.active]`)
- Added by PR #14395 ("allow Turn_exhausted from Turn_prompting/Turn_routing"), per progress memory.
- Active phase — keeper is mid-turn, fully observable state.
- Spec-wise unmodeled — `BindMeasurement`/`GuardOk`/`SelectToolPolicy` actions assume direct progression from prompting → executing.

### `Turn_exhausted` (`[@tla.terminal]`)
- Same PR #14395.  Terminal turn state (no progression).
- The OCaml comment at `keeper_registry.ml:169-172` directly admits the drift:
  > "Turn_routing and Turn_exhausted were added to the normal variant on main while this PR was in flight; the GADT tracks them too so the transition matrix below stays compile-time exhaustive."

### `[@tla.idle|active|terminal]` annotations as ground truth

OCaml uses `[@tla.idle]`, `[@tla.active]`, `[@tla.terminal]` PPX attributes on each variant.  These embed the spec-classification intent *in the OCaml type itself* — `Turn_routing [@tla.active]` is a documentation-level claim "this is an active phase per TLA+".  But the *spec* doesn't actually list these phases.  The annotation is forward-looking metadata that spec hasn't caught up on.

## How 7 invariants currently behave on the unmodeled phases

`KeeperTurnCycle.tla` invariants §316-352 quantify over `turn_phase \in TurnPhaseSet` (= 5-element set).  Since `Turn_routing` / `Turn_exhausted` are not in the set, an OCaml state machine that's currently in those phases is **outside the spec's universe**.  The 7 invariants — `NoLiveTurnClearsState`, `IdleRequiresNotLive`, `GateRejectedRequiresFinalizing`, `SelectingRequiresToolPolicy`, `ExecutingRequiresTrying`, `CompactingRequiresTrying`, `TerminalCascadeRequiresFinalizing` — say nothing about those phases.

This is a coverage gap, not a contradiction.  An OCaml run that enters `Turn_routing` and violates what *would be* a sensible "Routing should imply X" invariant is silently allowed at the spec level.  The Bug Model can't detect routing-related corruption because routing isn't in the universe.

## Three concrete invariant candidates for the missing phases

Drawn directly from OCaml's `[@tla.active|terminal]` annotations + production semantics inferred from #14395:

1. **`RoutingRequiresToolPolicy`** (spec extension):
   ```tla
   RoutingRequiresToolPolicy ==
       turn_phase = "routing" =>
           /\ turn_live
           /\ decision_stage = "tool_policy_selected"
           /\ cascade_state \in {"selecting", "trying"}
   ```
   Mirrors `SelectingRequiresToolPolicy` / `ExecutingRequiresTrying` for the routing phase.

2. **`ExhaustedRequiresTerminalCascade`** (spec extension):
   ```tla
   ExhaustedRequiresTerminalCascade ==
       turn_phase = "exhausted" =>
           /\ cascade_state = "exhausted"
   ```
   Mirrors the OCaml `[@tla.terminal]` annotation.  Exhausted should pair with cascade exhausted.

3. **`ExhaustedIsForever`** (spec extension):
   ```tla
   ExhaustedIsForever == [](turn_phase = "exhausted" => [](turn_phase = "exhausted"))
   ```
   Liveness — terminal phase shouldn't transition out (parallels `DeadIsForever` in KSM §S1).

## Suggested RFC fix paths

| ID | Scope | Action | Risk |
|---|---|---|---|
| R-B-1.a | Spec extension | Add `routing` and `exhausted` to `TurnPhaseSet`.  Add 3 new actions in `Next` (`EnterRouting`, `TurnExhausted`, transitions).  TLC re-verify. | MID — spec re-verification needed (5-15 min TLC). |
| R-B-1.b | Spec invariants | Add 3 invariants above to `Safety` after R-B-1.a.  Independent PR for review focus. | LOW — invariant addition only. |
| R-B-1.c | OCaml `[@tla.*]` annotation parsing | If a PPX/script validates that every `[@tla.*]` variant corresponds to a spec set member, the drift would be compile-time caught.  Currently the annotation is documentation-only. | MID — PPX work. |

R-B-1.a is the prerequisite for R-B-1.b.  R-B-1.c is the structural fix that prevents future occurrences.

## Out-of-scope for this iteration

- TLC re-verify with extended `TurnPhaseSet` — requires R-B-1.a's spec change first.
- B-2 `Turn_exhausted` transition matrix audit (post-#14395) — separate sub-aspect, will likely overlap.
- B-3 `SelectingRequiresToolPolicy` ↔ OCaml policy binding — separate sub-aspect.
- B-4 deadlock-free liveness — separate sub-aspect.

## References

- KTC spec line 98-112 (VARIABLES + 3-axis sets)
- KTC spec line 316-352 (7 safety invariants)
- OCaml `turn_phase` definition: `lib/keeper/keeper_registry.ml:158-166`
- OCaml `decision_stage`: `lib/keeper/keeper_registry.ml:295-300`
- OCaml `cascade_state`: `lib/keeper/keeper_registry.ml:385-391`
- Self-admission comment: `lib/keeper/keeper_registry.ml:168-172`
- PR #14395 (Turn_exhausted transitions, history reference)
- KSM A-1 audit pattern parallel: `docs/tla-audit/ksm-init-mapping-2026-05-12.md`
