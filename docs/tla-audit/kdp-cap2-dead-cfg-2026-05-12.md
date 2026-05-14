# KDP cap2.cfg — Dead config audit (born broken, silent since 2026-04-26)

**Iteration**: 44 (/loop FSM/TLA+/OCaml drift hunt)
**Date**: 2026-05-12
**File**: `specs/keeper-state-machine/KeeperDecisionPipeline-cap2.cfg` (22 LOC)
**Discovered**: iter 42 TLC verification matrix (PR #14834) reported `Error: The invariant ToolSetNeverEmpty specified in the configuration file is not defined in the specification.`
**Risk**: LOW — config has never been executable, so no production correctness impact. Spec hygiene only.
**Type**: Audit-only. Identifies a **new drift class**: "born-dead config" — committed alongside its parent .tla but referencing invariants/CONSTANTS that never existed in that .tla.

## What the cfg claims to do

```cfg
\* TLC Configuration: KeeperDecisionPipeline with PenaltyCapPerCycle = 2
\*
\* Robustness check: verify all properties hold even with higher penalty cap.
\* If this passes, the design is not brittle to cap value choices.
\* State space: ~19200 states (cap=2 doubles penalty dimension).

SPECIFICATION Spec

CONSTANTS
    MaxAlpha = 10
    MaxBeta = 10
    PenaltyCapPerCycle = 2
    TotalRemovableShards = 7
    RecoveryFloorSize = 1

INVARIANTS
    TypeOK
    ToolSetNeverEmpty
    RecoveryFloorMaintained

PROPERTIES
    FailingEventuallyRecovers
```

## What KeeperDecisionPipeline.tla actually defines

```
$ rg -n "CONSTANT|ToolSetNeverEmpty|RecoveryFloorMaintained|FailingEventuallyRecovers|MaxAlpha|MaxBeta|PenaltyCapPerCycle|TotalRemovableShards|RecoveryFloorSize" specs/keeper-state-machine/KeeperDecisionPipeline.tla
(no output)

$ rg -n "DecisionBoundary|NonIdleCascade" specs/keeper-state-machine/KeeperDecisionPipeline.tla
92:    "DecisionBoundaryRequiresMeasurement",
94:    "NonIdleCascadeRequiresDecisionBoundary",
219:DecisionBoundaryRequiresMeasurement ==
229:NonIdleCascadeRequiresDecisionBoundary ==
244:    /\ DecisionBoundaryRequiresMeasurement
246:    /\ NonIdleCascadeRequiresDecisionBoundary
```

**Zero matches** for any of the cap2.cfg's CONSTANTS / INVARIANTS / PROPERTIES in the parent spec. The spec defines `Safety` (line 244-246) which composes `DecisionBoundaryRequiresMeasurement` + `NonIdleCascadeRequiresDecisionBoundary`. Nothing about tools, recovery floors, penalty caps, removable shards, or alpha/beta bounds.

## TLC reproduction (iter 42 finding)

```bash
$ java -cp ~/.local/lib/tla/tla2tools-1.8.0.jar tlc2.TLC \
    -workers auto -cleanup \
    -config KeeperDecisionPipeline-cap2.cfg \
    KeeperDecisionPipeline.tla

Error: The invariant ToolSetNeverEmpty specified in the configuration file
is not defined in the specification.
Finished in 00s
```

Hard-fails before generating any states. The cfg has never been executable.

## Sibling `-cap2-buggy.cfg` works

Same CONSTANTS block (referencing names not in spec) but only invariant `DecisionBoundaryRequiresMeasurement` — which **does** exist. TLC silently ignores unused CONSTANTS values (the spec has no `CONSTANTS` section to bind them to), so the cfg runs:

```bash
$ java -cp ~/.local/lib/tla/tla2tools-1.8.0.jar tlc2.TLC \
    -config KeeperDecisionPipeline-cap2-buggy.cfg \
    KeeperDecisionPipeline.tla
[runs to completion, reports DecisionBoundaryRequiresMeasurement violated at state 3]
```

The cap2-buggy.cfg passes iter 42's matrix because TLC tolerates orphan CONSTANTS. The clean cap2.cfg fails because TLC validates INVARIANTS strictly.

## Git archaeology

```
$ git log --oneline -- specs/keeper-state-machine/KeeperDecisionPipeline-cap2.cfg
9faabfadf chore(eio_guard): drop deprecated with_rw/with_ro aliases (#10633)
```

The `chore(eio_guard)` commit (Apr 26, 2026, PR #10633) somehow batched in the cap2.cfg birth — likely a worktree leakage during a multi-spec import. PR #6336 (`feat(tla): harden KeeperDecisionPipeline with production constants`) introduced the names `MaxAlpha`/`PenaltyCapPerCycle`/etc into a *different* iteration of KDP.tla that was later reverted, but the cap2.cfg referencing them was preserved.

```
$ git log --all -S "ToolSetNeverEmpty" --oneline -- specs/keeper-state-machine/KeeperDecisionPipeline.tla
(no commits — ToolSetNeverEmpty was NEVER in KDP.tla)
```

So the cap2.cfg has been **dead since birth** (2026-04-26 — ~2 weeks at the time of this audit). No CI ever ran it (Makefile auto-derives `.tla` from `.cfg` base name and falls back to `-cap2.tla` which doesn't exist → SKIP). It only surfaces when manually targeted, which iter 42's `KDecisionPipeline-cap2.cfg` cross-check did.

## Why production stays correct (today)

- Spec safety surface is fully covered by `KeeperDecisionPipeline.cfg` (clean, uses `Safety` + `Liveness`) and `-buggy.cfg` (uses `DecisionBoundaryRequiresMeasurement` violation) — both verified post-iter-42 sync.
- The cap2.cfg "robustness check" stated purpose (`verify all properties hold even with higher penalty cap`) is moot because KDP.tla has **no penalty cap** in its model. There is nothing to vary.
- `INDEX.md` auto-discovers cfgs and lists cap2's claimed invariants as `cap2={inv:TypeOK, inv:ToolSetNeverEmpty, inv:RecoveryFloorMaintained, prop:FailingEventuallyRecovers}` — the index is **honest about the cfg contents** but does NOT verify they exist in the parent spec. This is a R-B-1.c chain analog: existing validator catches OCaml↔spec drift and spec↔spec drift, but NOT cfg↔spec orphan reference drift.

## Three RFC candidates

| ID | Direction | Risk | Effort |
|---|---|---|---|
| **R-F-1.a** | Delete the dead cfg pair (`-cap2.cfg` + `-cap2-buggy.cfg`). Update INDEX.md generator. Recover ~30 LOC. | LOW — no production impact, cfg never ran. | ~5 LOC delete + INDEX regen |
| **R-F-1.b** | Fix the cap2.cfg to match the parent spec — replace invariant set with `Safety` and remove orphan CONSTANTS / PROPERTIES. Keeps the "robustness with different state-space bounds" notion alive even though KDP doesn't have config-driven bounds. | LOW — cfg edit only. | ~10 LOC repair |
| **R-F-1.c** | Validator extension — extend `scripts/audit-tla-annotation-drift.sh` (or new sister script) with a *cfg↔spec orphan reference* check. For each `INVARIANTS`/`PROPERTIES`/`CONSTANTS` entry in any `.cfg`, verify the corresponding `.tla` declares it. Generic across all 25 specs. | MID — new validator pass, baseline format. | ~50-100 LOC bash + baseline |

**Recommended**: R-F-1.a (delete). Reasoning: (i) cfg has been silently broken since 2026-04-26 (~2 weeks) with zero CI signal — proves it's not load-bearing, (ii) its stated purpose ("robustness with PenaltyCapPerCycle = 2") is moot for the current KDP.tla (no penalty cap), (iii) R-F-1.b would preserve a misleading filename suggesting a parameter sweep that doesn't apply. R-F-1.c is the long-term structural fix — separate iter, paired with R-F-1.a or R-F-1.b on activation.

## New drift class — "born-dead config"

| Audit | Drift axis | Detection |
|---|---|---|
| KSM A-1 (#14694) | OCaml ↔ spec init mapping | Manual audit |
| KTC B-1 (#14767→#14793) | OCaml ↔ spec type-symbol | R-B-1.c validator (iter 20) |
| KCAF D-1/D-2 (#14798/#14815) | OCaml ↔ spec alphabet | Manual audit |
| KCL E-1 (#14822→#14824) | Spec ↔ spec projection | R-E-1.b cross-spec scanner (iter 40) |
| **KDP F-1 (this)** | **Cfg ↔ spec orphan reference** | **Manual TLC trigger** |

F-1 is a *fifth* drift class — narrower than the previous four (it requires TLC execution to surface, while the prior four were static), but identifies a category the validator chain has never modeled. R-F-1.c would close it structurally.

## Empirical observations beyond the immediate finding

- **INDEX.md drift**: line 31 claims cap2 cfg has `inv:TypeOK, inv:ToolSetNeverEmpty, inv:RecoveryFloorMaintained, prop:FailingEventuallyRecovers` — accurate to the cfg, **silent on spec compatibility**. INDEX generator could be the natural home for R-F-1.c.
- **Makefile auto-discovery skip**: `CLEAN_CFGS := $(shell find . -name '*.cfg' ...)` includes `KDP-cap2.cfg` but `check-clean` runs `tla="$dir/$base.tla"` and skips if `.tla` missing. cap2.cfg has no matching `-cap2.tla`, so CI silently SKIPs it. **Silent skip pattern** — same SilentFailure category as iter 2's `_ -> []` catch-all.
- **cap2-buggy works by accident**: TLC accepts orphan CONSTANTS without error; only orphan INVARIANTS/PROPERTIES hard-fail. So cap2-buggy.cfg (no orphan invariants) executes despite mismatched CONSTANTS. cap2.cfg (3 orphan invariants) errors. **TLC error surface asymmetry** — could be exploited as a future R-F-1.c heuristic.

## Out-of-scope for this iteration

- R-F-1.a/b/c implementation — separate PR(s).
- INDEX generator extension — coupling with R-F-1.c likely.
- Audit of *other* specs for the same pattern — `find specs/ -name '*.cfg' -exec ...` sweep needed (iter 45 candidate).
- KDP-cap2.cfg deletion via R-F-1.a — separate PR (audit-action separation per loop convention).

## References

- KeeperDecisionPipeline.tla (current state, post-iter-42 7-member TurnPhaseSet) — `Safety` invariant line 244-246.
- iter 42 PR #14834 — TLC matrix where this surfaced as orthogonal pre-existing error.
- iter 21 R-B-1.c CI integration (#14772) — precedent for paired-baseline policy in any future R-F-1.c.
- iter 38 KCL E-1 (`kcl-e1-cross-spec-projection-drift-2026-05-12.md`) — precedent for "new drift class discovered" memo structure.
- Git: `9faabfadf` (cap2.cfg birth commit), `d1c89ef13` PR #6336 (likely source of the dead invariant names, in a now-reverted KDP.tla revision).
- specs/INDEX.md:31 — auto-generated cap2 metadata showing the orphan claim.
- specs/Makefile §`check-clean` — `tla="$dir/$base.tla"` derivation + silent SKIP for missing .tla.
