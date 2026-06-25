---- MODULE KeeperLastBlockerLatch ----
\* Boundary spec for RFC-0082: Keeper last_blocker auto-clear + recovery escalation.
\*
\* Runtime truth being modelled
\* (lib/keeper/keeper_supervisor_pause_policy.ml stamps blocker-backed pauses,
\*  lib/keeper/keeper_unified_turn_failure.ml stamps runtime-exhausted blockers,
\*  lib/keeper/keeper_unified_turn_no_progress.ml clears no-progress blockers on
\*  a progress turn, and supervisor resume paths clear runtime.last_blocker when
\*  the keeper is auto/manual resumed):
\*
\*   - runtime_exhausted stamps keeper_meta.runtime.last_blocker.
\*   - runtime providers may later recover (network, credentials, restart).
\*   - Current code has explicit clear paths: progress-turn recovery clears
\*     No_progress_loop, auto-resume/reconcile resume clears paused blockers,
\*     and operator resume clears the latch.  This clean spec models those
\*     implementation paths as [ClearOnSuccess] / [OperatorClears].
\*   - SpecBuggy is retained only as a historical residual bug model: if those
\*     clear paths disappear, runtime_health can flip back to Healthy while
\*     last_blocker stays SET forever, which is the dashboard-stuck failure.
\*
\* What this spec deliberately abstracts away:
\*   - Probe interval, budget mechanics, fleet stale batch counting.
\*   - The actual runtime tier resolution (claude_code, kimi_cli, ollama).
\*   - The dashboard's read model — assumed faithful to keeper_meta.
\*
\* Bug Model (CLAUDE.md "TLA+ Bug Model pattern"):
\*   - Spec      (clean):    ClearOnSuccess action present;
\*                           liveness invariant LastBlockerEventuallyCleared holds.
\*   - SpecBuggy:            ClearOnSuccess removed; the same liveness
\*                           invariant is violated by a stuttering
\*                           sequence where runtime_health = Healthy
\*                           but last_blocker stays SET forever.
\*
\* Expected TLC outcome:
\*   - Clean.cfg:  LastBlockerEventuallyCleared holds.
\*   - Buggy.cfg:  LastBlockerEventuallyCleared violated (counterexample
\*                 within <= 4 steps: Fail -> ProviderRecovers -> stutter).

EXTENDS TLC, Naturals, Sequences

CONSTANTS
    MaxSteps             \* Upper bound on action firings to bound the state space

ASSUME MaxStepsPos == MaxSteps \in Nat /\ MaxSteps >= 4

VARIABLES
    last_blocker,        \* {"NONE", "SET"}
    runtime_health,      \* {"HEALTHY", "UNHEALTHY"}
    step_count           \* progress counter, bounds the state space

vars == << last_blocker, runtime_health, step_count >>

BlockerStates == {"NONE", "SET"}
HealthStates  == {"HEALTHY", "UNHEALTHY"}

(* ── Type invariant ─────────────────────────────────────── *)

TypeOK ==
    /\ last_blocker \in BlockerStates
    /\ runtime_health \in HealthStates
    /\ step_count \in 0..MaxSteps

(* ── Initial state ──────────────────────────────────────── *)
\* Keeper starts healthy with no blocker — the steady state
\* before any runtime exhaustion.

Init ==
    /\ last_blocker = "NONE"
    /\ runtime_health = "HEALTHY"
    /\ step_count = 0

(* ── Actions ────────────────────────────────────────────── *)

\* Runtime exhausts: a turn fires when runtime is healthy, then
\* providers go away (credential rotation, network blip, CLI binary
\* missing, etc).  This both flips health and stamps the blocker.
Fail ==
    /\ step_count < MaxSteps
    /\ runtime_health = "HEALTHY"
    /\ last_blocker = "NONE"
    /\ runtime_health' = "UNHEALTHY"
    /\ last_blocker' = "SET"
    /\ step_count' = step_count + 1

\* Provider recovers externally (operator brings CLI back, credentials
\* refresh, network heals).  This flips health but does NOT touch
\* last_blocker — the bug surface.
ProviderRecovers ==
    /\ step_count < MaxSteps
    /\ runtime_health = "UNHEALTHY"
    /\ runtime_health' = "HEALTHY"
    /\ UNCHANGED last_blocker
    /\ step_count' = step_count + 1

\* Current implementation clear paths: when runtime is healthy and a progress
\* turn or resume reconciliation succeeds (modelled here as a non-deterministic
\* firing gated on health), clear the latch.  SpecBuggy removes this action to
\* prove the historical invariant violation would come back if the OCaml clear
\* paths were lost.
ClearOnSuccess ==
    /\ step_count < MaxSteps
    /\ runtime_health = "HEALTHY"
    /\ last_blocker = "SET"
    /\ last_blocker' = "NONE"
    /\ UNCHANGED runtime_health
    /\ step_count' = step_count + 1

\* Operator manual clear via admin endpoint (Phase 3 in RFC-0082).
\* Independent of runtime health — operator may clear even when
\* runtime is still unhealthy, because they know the underlying
\* issue is being fixed.
OperatorClears ==
    /\ step_count < MaxSteps
    /\ last_blocker = "SET"
    /\ last_blocker' = "NONE"
    /\ UNCHANGED runtime_health
    /\ step_count' = step_count + 1

\* Stutter when bounded.  Stutter is required for liveness check
\* to find the deadlock — TLC needs to be able to "linger" in a
\* state to prove that the bad state persists.
Stutter ==
    /\ step_count >= MaxSteps
    /\ UNCHANGED vars

(* ── Spec (Clean) ───────────────────────────────────────── *)

Next ==
    \/ Fail
    \/ ProviderRecovers
    \/ ClearOnSuccess
    \/ OperatorClears
    \/ Stutter

Spec ==
    /\ Init
    /\ [][Next]_vars
    /\ WF_vars(ClearOnSuccess)
    /\ WF_vars(ProviderRecovers)

(* ── SpecBuggy ──────────────────────────────────────────── *)
\* Buggy variant: ClearOnSuccess action removed.  Only operator manual
\* intervention can clear the blocker.  Without that, the system can stutter in
\* (runtime_health = HEALTHY, last_blocker = SET) forever — the historical
\* production behaviour this spec keeps as a regression model.

NextBuggy ==
    \/ Fail
    \/ ProviderRecovers
    \/ OperatorClears
    \/ Stutter

\* For Buggy spec, deliberately omit WF for OperatorClears too
\* (operator may not intervene).  Only Fair Fail for progress.
SpecBuggy ==
    /\ Init
    /\ [][NextBuggy]_vars
    /\ WF_vars(ProviderRecovers)

(* ── Invariants ─────────────────────────────────────────── *)

\* Safety: types stay valid.
Safety == TypeOK

\* Liveness (the load-bearing claim):
\* Eventually, whenever runtime_health is HEALTHY, the blocker is
\* NONE.  In Clean: ClearOnSuccess fires under WF, so this holds.
\* In Buggy: there is no action that can take a (HEALTHY, SET)
\* state to (HEALTHY, NONE) without operator intervention; the
\* OperatorClears action exists but is not under WF in SpecBuggy,
\* so the system can stutter in (HEALTHY, SET) forever.
LastBlockerEventuallyCleared ==
    [](runtime_health = "HEALTHY" => <>(last_blocker = "NONE"))

\* No recovery deadlock: there is no infinite suffix where the
\* blocker stays SET despite runtime being healthy.  This is the
\* contrapositive form, useful for counterexample readability.
NoRecoveryDeadlock ==
    <>[](last_blocker = "SET" /\ runtime_health = "HEALTHY") => FALSE

====
