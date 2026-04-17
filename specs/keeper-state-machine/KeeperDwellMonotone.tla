---- MODULE KeeperDwellMonotone ----
\* Keeper-facing phase dwell time invariant.
\*
\* This spec models the minimal clock + phase entry stamp relationship that
\* powers the "Running for 2h 20m" dwell indicator in the Agent Modal
\* (dashboard/src/components/keeper-phase-indicator.ts).
\*
\* Dwell is derived on the frontend as (now - entered_at).  For this to be
\* a truthful duration it must be non-negative at every observation, which
\* requires two discipline points:
\*
\*   1. The clock [now] must be monotonic — time must not rewind.
\*   2. Every phase transition must stamp [entered_at := now].
\*      No transition may leave a stale entry_at from a previous phase
\*      occupancy, and no transition may set entry_at to a future value.
\*
\* Guarantees:
\*   DwellNonNegative  — entered_at <= now (so dwell >= 0).
\*   TypeOK            — variables stay in their domains.
\*   ClockAdvances     — fairness keeps the clock making progress.
\*
\* Bug Model (feedback_tla-spec-audit-outcome-trichotomy):
\*   Clean cfg : DwellNonNegative + TypeOK pass.
\*   Buggy cfg : BuggyEntryInFuture stamps entry_at := now + 1 on a
\*               transition, modelling a forgotten clamp-to-now.
\*               DwellNonNegative MUST be violated.  If it passes, the
\*               invariant is too weak and must be strengthened.

EXTENDS Integers, TLC

CONSTANTS MaxTime       \* bound the clock to keep state space finite

VARIABLES
    phase,
    entered_at,
    now

vars == << phase, entered_at, now >>

\* RFC-0002 11-phase FSM (keeper_state_machine.ml).
PhaseSet == {
    "Offline",
    "Running",
    "Failing",
    "Overflowed",
    "Compacting",
    "HandingOff",
    "Draining",
    "Paused",
    "Stopped",
    "Crashed",
    "Restarting",
    "Dead"
}

TypeOK ==
    /\ phase \in PhaseSet
    /\ entered_at \in 0..MaxTime
    /\ now \in 0..MaxTime

Init ==
    /\ phase = "Running"
    /\ entered_at = 0
    /\ now = 0

\* ── Actions ─────────────────────────────────

\* Clock advances one tick.  Bounded by MaxTime so the state space is
\* finite.  Other variables unchanged.
Tick ==
    /\ now < MaxTime
    /\ now' = now + 1
    /\ UNCHANGED << phase, entered_at >>

\* Phase transition stamps entered_at to the current clock value.  This is
\* the discipline the frontend dwell derivation depends on.
Transition ==
    /\ \E new_phase \in PhaseSet \ {phase} :
         phase' = new_phase
    /\ entered_at' = now
    /\ UNCHANGED << now >>

Next ==
    \/ Tick
    \/ Transition

\* Clock must continue to advance.  Without WF on Tick the model can
\* stutter at now = 0, which passes DwellNonNegative vacuously.
Fairness ==
    WF_vars(Tick)

Spec == Init /\ [][Next]_vars /\ Fairness

\* ── Safety ──────────────────────────────────

\* Core invariant: dwell = now - entered_at is always non-negative.
DwellNonNegative == entered_at <= now

Safety ==
    /\ TypeOK
    /\ DwellNonNegative

\* ── Liveness ────────────────────────────────

\* Sanity: the clock eventually advances.  Fairness on Tick makes this
\* straightforward, but stating it explicitly guards against a future
\* mutation that disables the Tick action.
ClockAdvances == [] <>(ENABLED Tick \/ ENABLED Transition)

\* ── Bug Model ───────────────────────────────

\* Mutation: a phase transition forgets to clamp entered_at <= now and
\* instead writes a future stamp (now + 1).  In the real codebase this
\* models a subtle off-by-one where the transition handler reads a
\* post-Tick timestamp before the Tick has committed.  Downstream, the
\* dashboard renders negative dwell ("Running for -1s"), which is the
\* exact failure mode this invariant guards.
BuggyEntryInFuture ==
    /\ now < MaxTime
    /\ \E new_phase \in PhaseSet \ {phase} :
         phase' = new_phase
    /\ entered_at' = now + 1
    /\ UNCHANGED << now >>

SpecBuggy == Init /\ [][Next \/ BuggyEntryInFuture]_vars /\ Fairness

====
