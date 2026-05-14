# KCL E-1 Audit — Cross-spec projection drift in observer sets

**Iteration**: 38 (/loop FSM/TLA+/OCaml drift hunt — first KCL/Phase E entry)
**Date**: 2026-05-12
**Spec**: `specs/keeper-state-machine/KeeperCompositeLifecycle.tla:135-144` (projection sets) + 624 LOC total
**Source specs observed**: KTC, KSM, KDP, KCR/KCL (cascade), KMC, KCAF, KPTO
**Risk**: HIGH — KCL's `TurnPhaseSet` is **2 members stale** vs KTC's post-iter-28 widening (#14793).  Joint invariants conditioning on `ktc_turn_phase` cannot reach routing/exhausted, so any joint property over those phases is **vacuously true** in TLC.  Highest-stakes drift class (cross-spec) — the validator chain (R-B-1.c iter 19-21-28-32-33) doesn't catch this because it scans OCaml→spec, not spec→spec.
**Type**: Audit-only.  **New drift class discovered**: cross-spec projection staleness.

## What KCL is

KCL is an **observer** spec, not a controller.  It declares projection
variables traceable to other sub-FSM (KSM/KTC/KDP/KCAF/KMC/KPTO) and
asserts joint invariants that no single-axis spec can express
(per header §"Purpose" lines 1-22).

7 joint invariants:
- PhaseTurnAlignment
- NoCascadeBeforeMeasurement
- CompactionAtomicity
- EventPriorityMonotone
- AttemptFSMRespectsAdmission
- ToolSurfaceFeedsAttempt
- PostTurnConsumesAttempt

Each conditions on multiple sub-FSM variables — the load-bearing
cross-spec safety surface.

## Finding 1 — KCL `TurnPhaseSet` stale by 2 members (HIGH)

```tla
\* specs/keeper-state-machine/KeeperCompositeLifecycle.tla:137
TurnPhaseSet == {"idle", "prompting", "executing", "compacting",
                 "finalizing"}   \* 5 members
```

vs:

```tla
\* specs/keeper-state-machine/KeeperTurnCycle.tla:127 (post-iter-28 #14793)
TurnPhaseSet == {"idle", "prompting", "routing", "executing",
                 "compacting", "finalizing", "exhausted"}   \* 7 members
```

Iter 28 (R-B-1.a, #14793 merged 2026-05-12) widened KTC's `TurnPhaseSet`
from 5 to 7 members to match OCaml's 7-constructor `turn_phase` GADT.
KCL was not updated.

**Consequence**: KCL's `ktc_turn_phase` variable can never take values
`"routing"` or `"exhausted"` — its `TypeOK` (line 165) requires
`ktc_turn_phase \in TurnPhaseSet`.  If KCL's actions advance to those
values, TLC fails on TypeOK.  Joint invariants conditioning on
`ktc_turn_phase` evaluate vacuously over those unreached values.

The R-B-1.c drift validator (iter 19-33 chain) catches OCaml↔spec
drift but **doesn't catch spec↔spec drift** like this.  Validator
`TYPE_SET_PAIRS` lists `turn_phase:TurnPhaseSet`, which (after
iter 33) checks against the spec corpus union — *KTC's* widened
set satisfies it.  KCL's *narrower* set isn't compared.

This is the **first cross-spec drift discovered** in the /loop —
a new class not anticipated by the audit-tool-CI chain.

## Finding 2 — KCL `KcafPhaseSet` intentional projection (MID, deliberate)

```tla
\* KCL.tla:143
KcafPhaseSet == {"idle", "attempting", "terminal"}   \* 3 members
```

vs:

```tla
\* KCAF.tla:79-81 (post-iter-30 audit + iter-37 honest-doc)
PhaseSet == {"idle", "attempting", "awaiting_response",
             "success", "exhausted_normal", "exhausted_hard_quota"}   \* 6 members
```

KCL deliberately collapses KCAF's 6 phases into 3 abstract values for
joint-invariant purposes.  This is the *observer pattern*: collapse
fine-grained phases into a coarser projection where the joint property
is expressible.

**However**, the collapse function `kcaf_phase → KcafPhaseSet` is
**not documented in KCL**.  Reader must infer:
- `idle` ↔ `idle` (1:1)
- `attempting` ↔ `attempting`, `awaiting_response` (2:1)
- `terminal` ↔ `success`, `exhausted_normal`, `exhausted_hard_quota` (3:1)

This collapse silently merges D-2's distinguished terminals
(`exhausted_normal` vs `exhausted_hard_quota`) — meaning any KCL joint
invariant conditioning on `kcaf_attempt_phase = "terminal"` cannot
distinguish hard-quota from normal exhaustion at the cross-spec level.
The D-2 safety surface
(`HardQuotaTerminalImmediate` + `BugHardQuotaBypass`) lives only in
KCAF, not in any cross-spec joint property.

## Finding 3 — Drift validator coverage gap (LOW, structural)

The R-B-1.c validator (iter 19/20/21/28/32/33) compares OCaml
`[@@deriving tla]` constructor names against spec set members,
union-merged across `${SPEC_DIR}/*.tla`.

It explicitly *does not* compare set definitions across specs —
this was a deliberate design choice (validator script line 89-100
comment: "Per-spec consistency... is a *separate* audit").

**Inferred consequence**: future spec-level extensions (like iter 28's
TurnPhaseSet widening) can leave observer specs (KCL, StateProduct,
KeeperContextLifecycle) silently stale.  The R-B-1.c chain catches
*type-symbol* drift only.

## Three RFC candidates

| ID | Direction | Risk |
|---|---|---|
| **R-E-1.a** | Spec — sync KCL's `TurnPhaseSet` to KTC's 7-member set.  Update joint invariants where applicable to handle new phases (RoutingStart, Routing → Executing, RoutingExhausted, etc.).  May require new KCL actions if existing actions can't reach the new phases — likely tractable since KCL is an observer (no new state machine logic). | LOW-MID — spec change, TLC re-verify, observer-style (no controller logic) |
| **R-E-1.b** | Validator — extend `scripts/audit-tla-annotation-drift.sh` to ALSO compare set definitions across `*.tla` files: when set `X` appears in multiple specs, flag the smaller as drift-suspect.  Bash union-difference + paired baseline for intentional projections (Finding 2 — KcafPhaseSet 3 vs 6 — would be baselined as deliberate). | MID — new validator pass, baseline format extension |
| **R-E-1.c** | Doc-only — KCL header documents the projection collapse explicitly (KcafPhaseSet 3:6:3 fan-in, with each KCAF phase mapped).  Doesn't close the TurnPhaseSet drift (that's R-E-1.a's job).  Matches iter 27/35/37 honest-doc pattern. | LOW (doc only) |

**Recommended**: R-E-1.a + R-E-1.c bundled.  Sync the stale set AND document the deliberate KCAF projection.  R-E-1.b is the long-term structural fix but a separate iter due to validator changes + baseline format extension.

## Why production stays correct (today)

- KTC's *own* spec catches turn_phase regressions via its own invariants — KCL drift weakens *cross-spec* coverage but doesn't blind KTC.
- The OCaml GADT (`keeper_registry.ml:234-244`) enforces compile-time exhaustiveness on `turn_phase` transitions independent of KCL.
- KCL's `kcaf_attempt_phase` projection silently collapses terminals, but D-2 audit (#14815) already noted KCAF's own bug model carries the safety surface.

So Finding 1 is a **coverage-breadth** gap, not a runtime bug.  But it's the **first cross-spec coverage gap** discovered — different from prior single-spec gaps (KSM A-1, KTC B-1, KCR C-1, KCT C-3, KCAF D-1/D-2).

## Cross-spec drift class — new family

| Audit | Drift axis | Detection |
|---|---|---|
| KSM A-1 (#14694) | OCaml ↔ spec init mapping | Manual audit |
| KTC B-1 (#14767→28) | OCaml ↔ spec type-symbol | R-B-1.c validator (iter 20) |
| KCAF D-1/D-2 (#14798/#14815) | OCaml ↔ spec alphabet | Manual audit |
| **KCL E-1 (this)** | **Spec ↔ spec projection** | **Manual audit (validator can't see this)** |

E-1 surfaces a new drift class that *no existing tool detects*.  This
broadens the audit chain's responsibility: future spec extensions
should check observer specs for stale projections, not just OCaml.

## Out-of-scope for this iteration

- R-E-1.a implementation — separate spec PR with TLC re-verify on both KCL clean + buggy cfgs.
- R-E-1.b validator extension — substantial bash + baseline format work, separate iter.
- KCL joint invariants deep audit — each of the 7 invariants warrants its own slice.
- StateProduct / KeeperContextLifecycle spec-pair drift check (other observers) — separate audit family.

## References

- KCL spec §1-48 (Purpose + Design intent), §61-79 (VARIABLES), §135-144 (projection sets).
- KTC spec §127 (TurnPhaseSet, iter 28-extended).
- KCAF spec §79-81 (PhaseSet, 6 members post-D-1/D-2 audits).
- iter 28 KTC R-B-1.a (#14793 ✓ merged) — source of the staleness.
- iter 19 KTC B-1 audit (`ktc-b1-turn-phase-spec-gap-2026-05-12.md`) — predecessor single-spec drift.
- iter 30 KCAF D-1 (`kcaf-d1-attempt-fsm-coverage-2026-05-12.md`) — predecessor input-alphabet drift.
- iter 36 KCAF D-2 (`kcaf-d2-exhausted-asymmetry-2026-05-12.md`) — terminal projection collapse.
- iter 37 KCAF R-D-2.c (#14817) — honest-doc precedent for R-E-1.c.
- Scripts/audit-tla-annotation-drift.sh:89-100 — explicit doc that per-spec consistency is out of scope (R-E-1.b would relax this).
