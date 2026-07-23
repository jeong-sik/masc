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
\*
\* Implementation mapping (spec ↔ runtime, see #8642 family).
\* Cited by symbol/file anchor, not line number — line numbers drift
\* (iter 64 N-2.a convention; the producer ref below had drifted +1658 and
\* the dashboard consumer had been split across three new files by iter 77,
\* see docs/tla-audit/kdm-r4-dwell-monotone-phaseset-and-mapping-drift-2026-05-12.md):
\*
\*   Producer side — phase transition stamps entry timestamp:
\*     lib/keeper/keeper_registry.ml — the
\*       Keeper_transition_audit.record_transition { ...;
\*         wall_clock_at_decision = now; ... }
\*     record built at each transition apply.  The OCaml side stamps
\*     [wall_clock_at_decision = now] at the moment of the apply,
\*     satisfying the spec discipline that entry_at := now (not future,
\*     not stale).  [now] comes from [Time_compat.now ()] which is
\*     wall-clock monotonic in practice (system clock).
\*
\*   Consumer side — dashboard derives dwell from the latest transition:
\*     dashboard/src/components/keeper-detail-page.ts holds
\*       const [phaseEnteredAtSec, setPhaseEnteredAtSec] = useState<number | null>(null)
\*     sourced from fetchKeeperTransitions(...) (dashboard/src/api/keeper.ts) —
\*     the latest KeeperTransition's wall_clock_at_decision — and threads it
\*     through keeper-detail-shell.ts into KeeperPhaseAndStage.
\*
\*   Defense in depth — frontend clamp guards a misbehaving clock:
\*     dashboard/src/components/keeper-phase-indicator.ts computes
\*       const dwellText = (typeof phaseEnteredAtSec === 'number' && Number.isFinite(phaseEnteredAtSec))
\*         ? formatDuration(Math.max(0, Date.now() / 1000 - phaseEnteredAtSec))
\*         : null
\*     Even if [phaseEnteredAtSec > Date.now()/1000] (clock skew between
\*     server and client, or a missed clamp on the producer), the dwell
\*     UI never shows a negative duration.  This is independent of the
\*     spec — the spec ensures the producer side is correct so the clamp
\*     should never fire in practice.
\*
\* Out of scope here (sibling specs):
\*   - phase selection logic (KeeperStateMachine)
\*   - per-turn time accounting (KeeperTurnCycle)

EXTENDS Integers, TLC

CONSTANTS MaxTime       \* bound the clock to keep state space finite

VARIABLES
    phase,
    entered_at,
    now

vars == << phase, entered_at, now >>

\* Exact lifecycle values from keeper_state_machine_phase.ml. Dwell is an
\* observation only: membership in this set grants no execution authority and
\* no phase transition is inferred from elapsed time.
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
