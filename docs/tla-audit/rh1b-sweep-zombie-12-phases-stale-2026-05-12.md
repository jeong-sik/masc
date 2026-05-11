# R-H-1.b Sweep — 8 specs carry stale "12 phases" reference (systemic drift)

**Iteration**: 49 (/loop FSM/TLA+/OCaml drift hunt)
**Date**: 2026-05-12
**Predecessor**: iter 47 KCtxL H-1 (#14850 ✓ merged) discovered Zombie omission; iter 48 R-H-1.a (#14856) fixed KCtxL.
**Scope**: observer spec sweep for Zombie-missing mapping tables and stale OCaml phase counts.
**Risk**: LOW finding (doc staleness only; spec reachable state graphs unchanged).
**Type**: Audit-only.  Classifies findings into 2 fix shapes for iter 50-51 implementation.

## Sweep result

Search: `rg -n "12 phases|12-phase|twelve phase|13 phases|13-phase" specs/keeper-state-machine/*.tla`

**8 specs** carry a stale "12 phases" or "12-phase" reference.  Ground truth (`keeper_state_machine.ml:6-19`) carries **13 phases** since iter 3-4 (#14702/#14707, Zombie addition).

| # | Spec | Lines | Phrase | Current PhaseSet members |
|---|---|---|---|---|
| 1 | KeeperContextLifecycle | 59 | "12 phases" | 7 (iter 48 #14856 in flight) |
| 2 | KeeperDwellMonotone | 71 | "12-phase FSM" | (no PhaseSet — comment-only ref) |
| 3 | KeeperGenerationLineage | 44 | "12 phases" | 3 (`idle`, `running`, `handing_off`) |
| 4 | KeeperLaunchPending | 29 | "12-phase variant" | (no PhaseSet — comment-only ref) |
| 5 | KeeperReconcileLiveness | 106 | "12 phases" | (uses DerivePhase reflection) |
| 6 | KeeperConditionsGovernPhase | 39, 59 | "12-phase variant" (×2) | 2 (`Running`, `HandingOff`) |
| 7 | KeeperCoreTriad | 26, 91, 92 | "12-phase OCaml type" + "12 phases into 7-symbol" | 7 |

Plus KMC and KCAF (counted in iter 38 KCL E-1 audit but not in this rg search — they don't say "12 phases" explicitly).

## Classification

Two distinct fix shapes:

### Shape A — Stale count comment (mechanical batch fix, 8+ specs)

The literal "12 phases" / "12-phase" string in spec comments.  Iter 3-4 (#14702/#14707) added Zombie as the 13th OCaml constructor; the comment count was never updated anywhere.

**Fix**: search-and-replace `12 phases` → `13 phases` and `12-phase` → `13-phase`, with iter 47/48 audit citation in the same line or follow-on sentence.

**Iter shape**: single batch PR (~8-12 LOC across 7+ specs), comment-only, no TLC behavioral change.

### Shape B — Missing Zombie mention in mapping table (per-spec, 3 specs)

Specs that carry detailed OCaml↔TLA+ mapping tables but never mention Zombie:

| # | Spec | Mapping table | Zombie status |
|---|---|---|---|
| B1 | KGenerationLineage | line 53+: `idle ↔ Offline\|Crashed\|Dead\|Restarting`, `running ↔ Running\|Failing\|Overflowed\|Compacting`, `handing_off ↔ HandingOff\|Draining\|Paused\|Stopped` | **Zombie missing** — should be in `idle` collapse (post-Dead siblings) or explicit unmodeled list |
| B2 | KCoreTriad | line 91+: 12-phase → 7-symbol collapse including "Terminal" | **Zombie missing** — likely belongs in `Terminal` collapse (which already includes Stopped+Crashed+Dead) |
| B3 | KReconcileLiveness | line 106+: DerivePhase reflection of OCaml | **Zombie missing** — DerivePhase doesn't model Zombie since it's post-Dead, but should document |

**Fix**: per-spec inline doc addition with terminal-terminal rationale (iter 48 KCtxL pattern, ~5-10 LOC each).  Each spec needs its own classification (collapse-into-Terminal vs unmodeled vs other).

**Iter shape**: 3 separate small PRs OR 1 bundle PR with 3 file changes.

### Specs that **don't** need fixes

- **KConditionsGovernPhase** — line 61 explicitly says "Adding new OCaml phases does NOT require updating this spec".  Stale "12-phase variant" is misleading but spec is intentionally scope-limited.  Shape A fix only.
- **KCompactionLifecycle** (KMC) — already iter 43 renamed sets (KMC_*) with documented projection scope.  No "12 phases" reference.  No action needed.
- **KCAF, KCL, KTC, KCascadeLifecycle, KDP** — already updated in prior iters (28/39/42/43).  Various phase coverages documented per-spec.
- **KToolSurface, KDwellMonotone, KLaunchPending** — surface-level / dwell-only / launch-only; no full FSM modeling.  Shape A fix only (count comment).
- **KEventQueue, KOASAdvanced, KWorkPipeline** — different domain (event/OAS/work), not KSM phase modeling.

## Pattern analysis

This is the **iter 38 KCL E-1 pattern at the count-comment dimension**.  KCL E-1 (set member dimension) was closed by iter 39 single-spec sync + iter 43 cross-spec rename.  KCtxL H-1 (mapping-comment dimension) was opened iter 47, closed for that one spec iter 48.  R-H-1.b sweep now reveals the **count-comment dimension** is *systemic* — 7+ specs all stale on the same KSM count.

**Drift class table evolution**:

| # | Class | Detection | First found | Status |
|---|---|---|---|---|
| 1 | OCaml ↔ spec init mapping (KSM A-1) | Manual | iter 1 (#14694) | Audit |
| 2 | OCaml ↔ spec type-symbol (KTC B-1) | R-B-1.c validator | iter 19 (#14767) | CI |
| 3 | OCaml ↔ spec alphabet (KCAF D-1/D-2) | Manual | iter 30 (#14798) | R-D-2.a deferred |
| 4 | Spec ↔ spec set member (KCL E-1) | R-E-1.b scanner | iter 38 (#14822) | CI iter 43 |
| 5 | Cfg ↔ spec orphan reference (KDP F-1) | `audit-tla-cfg-orphan.sh` | iter 44 (#14841) | Isolated 1-inst, closed iter 45 |
| 6 | **Spec doc count drift (R-H-1.b)** | **This sweep** | **iter 49 (this)** | **Systemic 7+ specs, R-H-1.c justified?** |

## R-H-1.c reconsideration

Iter 45/46 deferred R-F-1.c (validator extension for cfg↔spec orphan) citing "single instance".  R-H-1.b sweep reveals R-H-1's count-drift class is *systemic* (7+ instances vs F-1's 1 instance) — **the opposite threshold**.

If iter 50 batch-fixes the count comments and iter 51 fixes the 3 mapping-table cases, future PRs that update KSM's `phase` type will silently re-drift the same 7+ specs.  This is *exactly the recurring pattern* that justifies validator infrastructure (R-B-1.c precedent: KTC drift discovered → script written → CI activated).

**Recommended R-H-1.c shape**:

```bash
# scripts/audit-tla-phase-count.sh (~40-60 LOC)
# Read OCaml type phase constructor count from keeper_state_machine.ml
# rg "type phase|^  | [A-Z]" lib/keeper/keeper_state_machine.ml
# count = number of constructors
# Then sweep specs/keeper-state-machine/*.tla for "N phases" / "N-phase" patterns
# Flag where N != actual_count
# Exit 1 on mismatch
```

Wire into existing `tla-annotation-drift.yml` workflow as a separate pass.  Single source of truth (OCaml ground truth) drives the assertion.

**Decision**: R-H-1.c **promoted from deferred to recommended** (next-2-iter pipeline) given systemic recurrence evidence.

## Three RFC candidates

| ID | Direction | Risk |
|---|---|---|
| **R-H-1.b.1** | Batch count fix: `12 phases` → `13 phases` across 7+ specs | LOW — comment-only batch edit, no TLC behavior |
| **R-H-1.b.2** | Per-spec Zombie mapping mention (KGenerationLineage, KCoreTriad, KReconcileLiveness — 3 specs) | LOW (per-spec doc, ~5-10 LOC each) |
| **R-H-1.c** | Phase count validator (extends R-B-1.c chain) — was deferred iter 47, NOW recommended given systemic evidence | MID — ~40-60 LOC bash + CI wiring |

**Recommended order**:
1. Iter 50: R-H-1.b.1 batch count fix (mechanical, single PR).
2. Iter 51: R-H-1.b.2 mapping-table Zombie mentions (3 specs, single PR or stack).
3. Iter 52: R-H-1.c validator extension (paired-baseline + CI wiring).
4. Iter 53: Future-proof — KSM phase type evolution PRs become impossible to land without count update.

## Out-of-scope

- Implementation of any of the 3 RFCs.  Audit-only this iter.
- The 4-additional-unmodeled-phases (HandingOff, Draining, Paused, Restarting) cross-spec consistency.  Each spec's unmodeled list could also be audited — but those phases are *active* not terminal, so they appear in multiple specs (KGenerationLineage, KReconcileLiveness).  Lower priority than Zombie because phases that *appear* somewhere are easier to discover via grep than phases that *appear nowhere*.

## References

- iter 47 KCtxL H-1 audit (#14850 ✓ merged) — first surface of Zombie mapping-table gap
- iter 48 R-H-1.a apply (#14856 Draft) — KCtxL single-spec fix
- iter 38 KCL E-1 (`kcl-e1-cross-spec-projection-drift-2026-05-12.md`) — cross-spec staleness pattern
- iter 3 A-3 + iter 4 A-4 (#14702 ✓ + #14707) — Zombie introduction context
- iter 27/35/37/39 honest-doc pattern + iter 48 (5th datapoint) — fix-shape precedent
- iter 45/46 R-F-1.c deferral — single-instance threshold (opposite case from this sweep)
- iter 20 R-B-1.c validator (#14770 + #14772) — count validation precedent
