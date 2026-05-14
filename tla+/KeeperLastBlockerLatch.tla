---- MODULE KeeperLastBlockerLatch ----
\* Boundary spec for RFC-0082: Keeper last_blocker auto-clear + recovery escalation.
\*
\* Runtime truth being modelled
\* (lib/keeper/keeper_supervisor.ml:1485 stamps the blocker,
\*  lib/keeper/keeper_execution_receipt.ml:475 derives the disposition,
\*  no code path clears the blocker after recovery — that's the bug):
\*
\*   - cascade_exhausted stamps keeper_meta.runtime.last_blocker.
\*   - cascade providers may later recover (network, credentials, restart).
\*   - In the buggy code, last_blocker is never assigned None from a
\*     non-None state.  cascade_health can flip back to Healthy
\*     and a subsequent successful turn can run — but the latch field
\*     stays SET, which is what the dashboard reads to show
\*     "일시정지 / 런타임 차단", perpetuating the appearance of stuck.
\*
\* What this spec deliberately abstracts away:
\*   - Probe interval, budget mechanics, fleet stale batch counting.
\*   - The actual cascade tier resolution (claude_code, kimi_cli, ollama).
\*   - The dashboard's read model — assumed faithful to keeper_meta.
\*
\* Bug Model (CLAUDE.md "TLA+ Bug Model pattern"):
\*   - Spec      (clean):    ClearOnSuccess action present;
\*                           liveness invariant LastBlockerEventuallyCleared holds.
\*   - SpecBuggy:            ClearOnSuccess removed; the same liveness
\*                           invariant is violated by a stuttering
\*                           sequence where cascade_health = Healthy
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
    cascade_health,      \* {"HEALTHY", "UNHEALTHY"}
    step_count           \* progress counter, bounds the state space

vars == << last_blocker, cascade_health, step_count >>

BlockerStates == {"NONE", "SET"}
HealthStates  == {"HEALTHY", "UNHEALTHY"}

(* ── Type invariant ─────────────────────────────────────── *)

TypeOK ==
    /\ last_blocker \in BlockerStates
    /\ cascade_health \in HealthStates
    /\ step_count \in 0..MaxSteps

(* ── Initial state ──────────────────────────────────────── *)
\* Keeper starts healthy with no blocker — the steady state
\* before any cascade exhaustion.

Init ==
    /\ last_blocker = "NONE"
    /\ cascade_health = "HEALTHY"
    /\ step_count = 0

(* ── Actions ────────────────────────────────────────────── *)

\* Cascade exhausts: a turn fires when cascade is healthy, then
\* providers go away (credential rotation, network blip, CLI binary
\* missing, etc).  This both flips health and stamps the blocker.
Fail ==
    /\ step_count < MaxSteps
    /\ cascade_health = "HEALTHY"
    /\ last_blocker = "NONE"
    /\ cascade_health' = "UNHEALTHY"
    /\ last_blocker' = "SET"
    /\ step_count' = step_count + 1

\* Provider recovers externally (operator brings CLI back, credentials
\* refresh, network heals).  This flips health but does NOT touch
\* last_blocker — the bug surface.
ProviderRecovers ==
    /\ step_count < MaxSteps
    /\ cascade_health = "UNHEALTHY"
    /\ cascade_health' = "HEALTHY"
    /\ UNCHANGED last_blocker
    /\ step_count' = step_count + 1

\* The proposed fix: when cascade is healthy and a successful
\* call happens (modelled here as a non-deterministic firing
\* gated on health), clear the latch.  This is the action that
\* SpecBuggy removes to prove the invariant violation.
ClearOnSuccess ==
    /\ step_count < MaxSteps
    /\ cascade_health = "HEALTHY"
    /\ last_blocker = "SET"
    /\ last_blocker' = "NONE"
    /\ UNCHANGED cascade_health
    /\ step_count' = step_count + 1

\* Operator manual clear via admin endpoint (Phase 3 in RFC-0082).
\* Independent of cascade health — operator may clear even when
\* cascade is still unhealthy, because they know the underlying
\* issue is being fixed.
OperatorClears ==
    /\ step_count < MaxSteps
    /\ last_blocker = "SET"
    /\ last_blocker' = "NONE"
    /\ UNCHANGED cascade_health
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
\* Buggy variant: ClearOnSuccess action removed.  Only operator
\* manual intervention can clear the blocker.  Without that, the
\* system can stutter in (cascade_health = HEALTHY, last_blocker = SET)
\* forever — exactly the production behaviour we observed.

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
\* Eventually, whenever cascade_health is HEALTHY, the blocker is
\* NONE.  In Clean: ClearOnSuccess fires under WF, so this holds.
\* In Buggy: there is no action that can take a (HEALTHY, SET)
\* state to (HEALTHY, NONE) without operator intervention; the
\* OperatorClears action exists but is not under WF in SpecBuggy,
\* so the system can stutter in (HEALTHY, SET) forever.
LastBlockerEventuallyCleared ==
    [](cascade_health = "HEALTHY" => <>(last_blocker = "NONE"))

\* No recovery deadlock: there is no infinite suffix where the
\* blocker stays SET despite cascade being healthy.  This is the
\* contrapositive form, useful for counterexample readability.
NoRecoveryDeadlock ==
    <>[](last_blocker = "SET" /\ cascade_health = "HEALTHY") => FALSE

====
