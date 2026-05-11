# Cross-spec divergences — classify the 3 found by iter 40 scanner

**Iteration**: 41 (/loop FSM/TLA+/OCaml drift hunt)
**Date**: 2026-05-12
**Scanner**: `scripts/audit-tla-annotation-drift.sh --check-cross-spec` (iter 40 #14828)
**Risk**: MID — 7 divergence instances across 3 set names + 4 source specs.  Each instance needs explicit classification before iter 42 CI activation.
**Type**: Audit-only.  Classifies each divergence as STALE (sync) / DELIBERATE (rename) / NAME COLLISION (rename to distinct).

## Scanner output (iter 41 re-run on main post-#14828)

```
── TurnPhaseSet cross-spec (5 spec(s), 3 unique signature(s)) ──
  KeeperCascadeLifecycle:    compacting executing finalizing idle prompting          (5)
  KeeperCompactionLifecycle: compacting executing idle prompting                     (4)
  KeeperCompositeLifecycle:  compacting executing exhausted finalizing idle prompting routing (7) ← canonical
  KeeperDecisionPipeline:    compacting executing finalizing idle prompting          (5)
  KeeperTurnCycle:           compacting executing exhausted finalizing idle prompting routing (7) ← canonical

── DecisionSet cross-spec (6 spec(s), 3 unique signature(s)) ──
  KeeperCascadeLifecycle:    gate_rejected guard_ok tool_policy_selected undecided   (4) ← canonical
  KeeperCompactionLifecycle: guard_ok tool_policy_selected undecided                 (3)
  KeeperCompositeLifecycle:  gate_rejected guard_ok tool_policy_selected undecided   (4) ← canonical
  KeeperDecisionPipeline:    gate_rejected guard_ok tool_policy_selected undecided   (4) ← canonical
  KeeperEventQueue:          emit skip tick                                          (3) ← NAME COLLISION
  KeeperTurnCycle:           gate_rejected guard_ok tool_policy_selected undecided   (4) ← canonical

── CascadeSet cross-spec (5 spec(s), 2 unique signature(s)) ──
  KeeperCascadeLifecycle:    done exhausted idle selecting trying                    (5) ← canonical
  KeeperCompactionLifecycle: idle trying                                             (2)
  KeeperCompositeLifecycle:  done exhausted idle selecting trying                    (5) ← canonical
  KeeperDecisionPipeline:    done exhausted idle selecting trying                    (5) ← canonical
  KeeperTurnCycle:           done exhausted idle selecting trying                    (5) ← canonical
```

## Classification

| Set | Spec file | Status | Classification | Recommended fix |
|---|---|---|---|---|
| TurnPhaseSet | KeeperCascadeLifecycle | 5 vs canonical 7 | **STALE** (missing routing, exhausted) | Sync to 7 (iter 39 R-E-1.a pattern) |
| TurnPhaseSet | KeeperDecisionPipeline | 5 vs canonical 7 | **STALE** (missing routing, exhausted) | Sync to 7 |
| TurnPhaseSet | KeeperCompactionLifecycle | 4 (missing finalizing too) | **DELIBERATE** — KMC header §"Out-of-scope" explicitly projects compaction-focused phases only.  Different size + shape from canonical. | Rename to `KMC_TurnPhaseSet` or `KMCPhaseSet`; document projection rationale |
| DecisionSet | KeeperCompactionLifecycle | 3 (missing gate_rejected) | **DELIBERATE** — gate rejection doesn't enter compaction flow; KMC observes only the decision_stage values the compaction recovery loop cares about | Rename to `KMC_DecisionSet` |
| DecisionSet | KeeperEventQueue | 3 ("emit", "skip", "tick") | **NAME COLLISION** — completely different vocabulary; this is the Event Queue's *own* decision space (`Heartbeat_smart.should_emit`), not decision_stage projection | Rename to `EventQueueDecisionSet` or `SmartHeartbeatDecisionSet`; KEQ has unique vocabulary unrelated to keeper-turn decision |
| CascadeSet | KeeperCompactionLifecycle | 2 (idle, trying only) | **DELIBERATE** — compaction observes only "cascade running" vs "cascade idle" boundary | Rename to `KMC_CascadeSet` |

## Three classes, three fix shapes

### Class A — STALE (sync, like iter 39)

Two specs (KeeperCascadeLifecycle, KeeperDecisionPipeline) carry the pre-iter-28 5-member `TurnPhaseSet`.  Same root cause as KCL (iter 38 Finding 1, closed iter 39 R-E-1.a): KTC widened the set in iter 28 (#14793); these observer specs were not synced.

**Fix shape**: 1-line widening per spec to 7 members, mirroring iter 39 #14824.  Same `ktc_turn_phase` usage scan precaution — verify no negative full-set membership tests that would regress with widening.  Likely paired-PR with the rename work (Class B/C).

### Class B — DELIBERATE PROJECTION (rename to distinct identifier)

KeeperCompactionLifecycle defines TurnPhaseSet (4), DecisionSet (3), CascadeSet (2) as *intentional* partial projections — header explicitly states "intentionally a projection, not a full copy" (line 9-15).  The 4-phase scope (Running/Overflowed/Compacting/Paused) is documented; sibling specs (KeeperContextLifecycle, KeeperCircuitBreaker) cover the rest.

**Fix shape**: rename each KMC-local set:
- `TurnPhaseSet` → `KMC_TurnPhaseSet` (or `KMCPhaseSet`)
- `DecisionSet`  → `KMC_DecisionSet`
- `CascadeSet`   → `KMC_CascadeSet`

Matches iter 38 audit recommendation: "if the projection is DELIBERATE (observer pattern), rename to a distinct identifier (e.g. KcafPhaseSet vs PhaseSet) and document in the spec header."

This is also the *iter 39 R-E-1.c precedent* for KCL's `KcafPhaseSet`: the deliberate 3:6 collapse uses a distinct name and inline mapping.

### Class C — NAME COLLISION (rename to unrelated identifier)

KeeperEventQueue defines `DecisionSet` with values `{"emit", "skip", "tick"}` — the Event Queue's own decision vocabulary, not the keeper-turn decision_stage.  Header (lines 8-23) clearly identifies this as `Heartbeat_smart.should_emit (Emit/Skip)` output.

The identifier collision is *accidental* — KEQ wasn't aware that `DecisionSet` was an established cross-spec identifier for keeper-turn decision projection.

**Fix shape**: rename to a vocabulary-aligned name:
- `DecisionSet` → `SmartHeartbeatDecisionSet` or `EventQueueDecisionSet`

Header already documents the semantics; rename clarifies the boundary.

## Iter 42 implementation plan

Bundle all 7 fixes in a single PR (`spec(multi): cross-spec divergence closure — R-E-1.a {KCascadeL,KDP} + KMC/KEQ rename`):

1. **Stale sync** (2 changes, like iter 39):
   - `KeeperCascadeLifecycle.tla`: TurnPhaseSet 5 → 7
   - `KeeperDecisionPipeline.tla`: TurnPhaseSet 5 → 7

2. **Deliberate rename** (3 changes in 1 file):
   - `KeeperCompactionLifecycle.tla`: rename `TurnPhaseSet` → `KMC_TurnPhaseSet`, `DecisionSet` → `KMC_DecisionSet`, `CascadeSet` → `KMC_CascadeSet`.  Update all usages (TypeOK, Init, actions, invariants) within the file.

3. **Name collision rename** (1 change):
   - `KeeperEventQueue.tla`: rename `DecisionSet` → `SmartHeartbeatDecisionSet`.  Update usages.

After all 7 fixes:
- Scanner cross-spec check: `0 cross-spec drift(s)` — clean.
- iter 42 PR pairs the cleanup with **CI activation** (`--check-cross-spec` enabled in workflow).
- iter 28 + iter 33 paired-update precedent applies.

## TLC verification matrix (iter 42)

Each touched spec needs both clean + buggy cfg re-verify:
- KCascadeLifecycle.cfg (clean) + buggy variants
- KDecisionPipeline.cfg (clean) + buggy variants
- KCompactionLifecycle.cfg (clean) + buggy variants
- KeeperEventQueue.cfg (clean) + buggy variants

All renames preserve TLC behavior because they're identifier-level changes.  The 2 stale syncs (Class A) are type-widening (iter 39 pattern, preserves reachable state graph).

If TLC clean state count changes for any spec post-rename, that's a *unexpected* effect (rename should be semantically transparent) requiring investigation.

## Why production stays correct (today)

- iter 40's scanner is opt-in only (default off in CI).  Currently *no* PR fails because of these 7 divergences.
- KMC and KEQ are observer specs; their partial projections don't model invariants the OCaml runtime depends on.
- iter 39 closed the highest-impact instance (KCL TurnPhaseSet) so KCL's joint invariants now cover routing/exhausted.

## Out-of-scope

- iter 42 implementation (separate PR with TLC verify matrix).
- Validator extension to detect *NAME COLLISIONS* automatically (could compare set member vocabularies for similarity, but probably not worth the false-positive risk).
- KSM phase set extension to validator (mentioned in script line 83-87 deferral comment).

## References

- iter 38 KCL E-1 audit (`kcl-e1-cross-spec-projection-drift-2026-05-12.md`) — first discovery of spec↔spec drift class.
- iter 39 R-E-1.a+c bundle (#14824 ✓ merged) — STALE-sync precedent.
- iter 40 R-E-1.b scanner (#14828 ✓ merged) — capability that surfaced these.
- iter 28 R-B-1.a (#14793 ✓ merged) — paired-baseline precedent.
- iter 33 R-D-1.b activation (#14804 ✓ merged) — paired-activation precedent.
- KCompactionLifecycle.tla header §"Out-of-scope" — explicit projection rationale.
- KeeperEventQueue.tla header §"Runtime entities modelled" — Heartbeat_smart.should_emit boundary.
