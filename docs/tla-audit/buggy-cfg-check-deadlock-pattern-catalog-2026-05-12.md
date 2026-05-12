# `-buggy.cfg` `CHECK_DEADLOCK` pattern catalog (iter 98, post-OPB R-12.a closure)

**Date**: 2026-05-12 · **Iteration**: 98 · **Phase**: meta-audit (iter 97 OPB R-12.a follow-up — *family quantification*)

## What this is

iter 97 #15008 fixed `OperatorPauseBroadcast-buggy.cfg`'s deadlock-masking-property quirk by adding `CHECK_DEADLOCK FALSE`. The iter 87 OPB R-12 audit (#14977) had described this as one instance of a family ("KMC-buggy `TypeOK`-first 같은 family"). Question: how many *other active canonical* instances are there in `specs/keeper-state-machine/`, and are any silently failing to surface their intended property violation?

This memo enumerates 31 active canonical `*-buggy.cfg` files in the keeper-state-machine spec directory, classifies each one's `NextBuggy` *shape*, cross-checks the `CHECK_DEADLOCK` setting in its cfg, and identifies the residual risk surface. It is comments-only / docs-only — no spec or cfg edits. The raw directory contains 35 `*-buggy.cfg` files; this active inventory excludes the already-closed `OperatorPauseBroadcast-buggy.cfg` case plus three non-canonical entries: `KeeperCampaignLifecycle-buggy.cfg` (orphan cfg without a matching `.tla`), `KeeperContextLifecycle-ci-buggy.cfg` (CI variant), and `KeeperStateMachine-overflow-buggy.cfg` (overflow variant).

## Method

For each active canonical `<Spec>-buggy.cfg` in `specs/keeper-state-machine/`:
1. Read the cfg, look for a `CHECK_DEADLOCK` directive (any value, any line shape).
2. Read the matching `<Spec>.tla`, find the `NextBuggy` definition.
3. Classify `NextBuggy` shape:
   - **add-bug** — `NextBuggy == Next \/ BugAction` (or `\/ Next \/ BugAction(...)`). Adds a bug-only transition on top of the clean transition set. *Cannot* deadlock if `Next` itself is deadlock-free (the bug transition only *adds* enabled actions).
   - **replace-bug** — `NextBuggy` is a *redefinition* (its disjuncts do not include `Next`). May drop or substitute clean actions. *Can* deadlock if a clean action that prevented stuck states is dropped.

## Inventory (31 cfgs)

### Class A — `CHECK_DEADLOCK FALSE` + add-bug (safe; explicit option present but not strictly required)

| Spec | `NextBuggy` shape |
|---|---|
| `KeeperAdmissionLiveness` | `Next \/ BugAction_GreedyKeeper(k)` |
| `KeeperCascadeAttemptFSM` | `Next \/ BugHardQuotaBypass` |
| `KeeperCascadeRouting` | `Next \/ BugIgnoreHealth(k)` |
| `KeeperPostTurnOrchestration` | `Next \/ BugWireinOutOfOrder` |
| `KeeperReactionLiveness` | `Next \/ BugSilentStimulusDrop` |
| `KeeperSocialModelMagenticLedger` | `Next \/ BugStalledWithoutCause` |
| `KeeperToolSurface` | `Next \/ BugRequiredEscapesValidate` |
| `KeeperTurnCycle` | `Next \/ BugSelectingWithoutToolPolicy` |

Eight specs. The `CHECK_DEADLOCK FALSE` is *defensive belt-and-braces* here — the option matters only if `Next` itself can reach a deadlock (no enabled actions), which would already be a bug in the clean spec.

### Class B — `CHECK_DEADLOCK FALSE` + replace-bug (safe; option load-bearing)

| Spec | `NextBuggy` shape |
|---|---|
| `KeeperCircuitBreaker` | `RecordSuccess \/ RecordFailureBuggy` (drops clean `RecordFailure`) |
| `KeeperContextLifecycle` | `StartTurn \/ TurnProducesOutput` (drops other clean actions) |
| `KeeperCoreTriad` | `BecomeFailing \/ BecomeCompacting` (full rewrite) |
| `KeeperGenerationLineage` | `\E k : StartTurn(k)` only |
| `KeeperMemoryLifecycle` | `CaptureShort \/ CaptureMid` (drops Eviction, Recovery) |
| `KeeperReconcileLiveness` | `HeartbeatOk \/ HeartbeatFailed \/ TurnSucceeded \/ TurnFailed` |
| `KeeperRolloverDecision` | `step < MaxSteps /\ \E ah ...` (subset of clean) |
| `KeeperStateMachine` | `HeartbeatOk \/ HeartbeatFailed \/ TurnSucceeded \/ TurnFailed` (4 of 18 actions) |
| `KeeperTurnSlot` | `AcquireProductive \/ ProductiveTick` (drops Yield, Idle) |

Nine specs. Here `CHECK_DEADLOCK FALSE` is *load-bearing*: if the redefined `NextBuggy` ever leaves the system in a state with no enabled action (and that state is *not* the intended end of the trace), TLC would otherwise report "Deadlock reached" before evaluating temporal properties — masking the intended `<liveness/safety>` violation. The OPB R-12.a fix (iter 97) had this same load-bearing shape, but is tracked below as a historical closure rather than counted in the 31 active canonical entries.

### Class C — `CHECK_DEADLOCK FALSE` + (no `NextBuggy` in `.tla`)

| Spec | Reason |
|---|---|
| `KeeperCascadeLifecycle` | Bug action defined inline in `Spec` body, not separate `NextBuggy` |
| `KeeperCompactionLifecycle` | Same |
| `KeeperConditionsGovernPhase` | Same |
| `KeeperCounterCausality` | Same |
| `KeeperDecisionPipeline` | Same |
| `KeeperDwellMonotone` | Same |
| `KeeperOutcomesConservation` | Same |
| `KeeperTraceSpec` | Trace replay, not buggy-model |

Eight specs. These were not analyzed for shape because the bug action's structural position differs; the `CHECK_DEADLOCK FALSE` setting is honored regardless.

### Class D — *NO* `CHECK_DEADLOCK` + add-bug (likely-safe, but unverified)

| Spec | `NextBuggy` shape | Risk |
|---|---|---|
| `KeeperApprovalQueue` | `Next \/ ExpireStaleNoResolve` | LOW — add-bug pattern, clean spec deadlock-free assumed |
| `KeeperEventQueue` | `Next \/ TickStarvesQueue` | LOW |
| `KeeperHeartbeat` | `Next \/ MissedWakeup` | LOW |
| `KeeperLaunchPending` | `Next \/ FiberStartedWithoutClearing` | LOW |
| `KeeperOASAdvanced` | `Next \/ CancelledAbsorbed` | LOW |
| `KeeperTaskAcquisition` | `Next \/ TaskRejected` | LOW |

Six specs. Each adds a single bug action to the clean `Next`. *Provided* the clean spec is deadlock-free (which `<Spec>.cfg` verifies via TLC default `CHECK_DEADLOCK`), the buggy spec is too — bug action only adds enabled transitions. Empirical TLC verification of buggy run + counterexample shape is **deferred** (Class D entries have not been observed to mask their intended violation, but no proof).

### Class E — *NO* `CHECK_DEADLOCK` + replace-bug (the iter 97 closure target)

| Spec | Status |
|---|---|
| `OperatorPauseBroadcast` | **CLOSED** by iter 97 #15008; historical closure, not counted in active inventory |

One historical spec. The R-12.a fix added `CHECK_DEADLOCK FALSE`, so the active Class E count is now zero.

## Summary table

| Class | Setting | Shape | Count | Status |
|---|---|---|---|---|
| A | `CHECK_DEADLOCK FALSE` | add-bug | 8 | safe (defensive option) |
| B | `CHECK_DEADLOCK FALSE` | replace-bug | 9 | safe (option load-bearing) |
| C | `CHECK_DEADLOCK FALSE` | no `NextBuggy` | 8 | safe (different shape) |
| D | *(missing)* | add-bug | 6 | likely-safe, unverified |
| E | *(missing)* | replace-bug | 0 | empty after iter 97 |
| **Total** | | | **31** | |

## Findings

1. **OPB was unique in Class E** — the only `-buggy.cfg` in `specs/keeper-state-machine/` where the combination of a missing `CHECK_DEADLOCK FALSE` *and* a redefined `NextBuggy` could (and did) mask the intended property violation. iter 97 closed it.
2. **Class D (6 specs) is the only remaining ambiguity** — `add-bug` shape *should* be deadlock-free if the clean spec is, but this is not empirically confirmed per-spec. None has been reported to mask its violation.
3. **No structural fix is needed in this PR** — adding `CHECK_DEADLOCK FALSE` to Class D specs would be a defensive change without an observed failure mode. CLAUDE.md §Workaround Rejection Bar's *inverse anti-pattern* (single-instance infrastructure) applies in *miniature* here: 6 unconfirmed-deadlock specs do not motivate pre-emptive cfg widening. Re-evaluate only if a Class D spec is observed to mask a violation (then fix at that time).
4. **Cross-dir parallel** — `specs/cascade/CascadeAttemptLiveness-buggy.cfg` and `specs/multimodal/MultimodalArtifact-buggy.cfg` both already carry `CHECK_DEADLOCK FALSE`. The same Class-by-shape sweep across non-keeper spec dirs is a follow-up (see below).

## Why this is not a workaround

CLAUDE.md §워크어라운드 거부 기준 #3 ("N-of-M 패치") targets "complete the migration" PRs that fan out a single transform to all N sites without a structural fix. This memo *intentionally does not* widen `CHECK_DEADLOCK FALSE` to the 6 Class D specs. The structural fix is the pattern-recognition signal itself: *new* `-buggy.cfg` files should be authored against this catalog (Class B/E shapes require the option; Class A/D may add it defensively).

## Follow-up

- **Class D empirical verification** (deferred): run TLC on each of the 6 Class D specs and confirm the buggy run exits via property violation, not deadlock. Time-bounded; low priority because no Class D failure has been observed.
- **Non-keeper-state-machine dirs**: `specs/cascade/`, `specs/bug-models/`, `specs/multimodal/`, `specs/server-state/`, `specs/state-product/`, `specs/admission-queue/`, `specs/auth/`, `specs/task-lifecycle/`, and `specs/keeper-turn-fsm/` have their own `-buggy.cfg` populations. A corpus-wide sweep would close the last classification gap. Out of this memo's scope.
- **`-buggy.cfg` authoring guide**: this catalog is a candidate baseline for a short `specs/AUTHORING-BUGGY-CFGS.md` (or a section of an existing README) covering: (a) class shape rules, (b) when `CHECK_DEADLOCK FALSE` is required vs defensive, (c) precedent citations. Deferred — corpus must stabilize first.

## Verification

- `for f in specs/keeper-state-machine/*-buggy.cfg; do grep -L CHECK_DEADLOCK "$f"; done` → 6 paths (Class D).
- `grep -A2 ^NextBuggy specs/keeper-state-machine/<Spec>.tla` per spec — shape extracted.
- iter 97 #15008 already in `origin/main` (commit `3fc1b0f98`); base of this memo is `162f89631`.

## Trade-offs

- **Pre-emptive class-D widening rejected** (anti-pattern: single-instance infrastructure for unconfirmed failure mode).
- **Empirical TLC verification of Class D deferred** — total run time ~minutes per spec; not worth the budget without an observed failure.
- **Corpus-wide sweep deferred** — keeper-state-machine is the most-changed dir; non-keeper dirs are stable.
