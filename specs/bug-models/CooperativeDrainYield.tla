---- MODULE CooperativeDrainYield ----
\* Bug model: Eio drain loop without cooperative yield starves co-located fibers.
\*
\* Models the regression introduced by PR #14491 (Keeper_telemetry_consumer
\* drain loop) and fixed by PR #14499. RFC-0063 §6 codifies the contract;
\* this spec is the §7-C ("TLA+ Bug Model") layer of enforcement.
\*
\* Cooperative scheduling premise
\*   A single Eio domain runs at most one fiber at a time. A fiber retains
\*   the domain until it explicitly yields (Eio.Time.sleep / Eio.Fiber.yield
\*   / blocking IO). A co-located fiber receives turns only while the drain
\*   fiber is in the "yielded" state.
\*
\* Two scheduler models
\*   Clean (NextClean):
\*     drain runs one iteration -> yields -> co-fiber may step -> drain
\*     resumes -> ... Co-fiber receives turns; co_progress reaches the
\*     target within a bounded number of drain iterations.
\*
\*   Buggy (NextBuggy):
\*     drain runs an iteration but never yields. drain_state stays
\*     "running" forever. Co-fiber's enabling guard (drain_state =
\*     "yielded") never holds; co_progress stays 0 while drain_iters
\*     grows without bound.
\*
\* Safety invariant
\*   NoStarvation: it is never the case that drain has run more than
\*   SafetyBound iterations while co_progress remains zero. Holds under
\*   NextClean; violated under NextBuggy in SafetyBound + 1 steps.

EXTENDS Naturals

CONSTANTS
    TargetProgress,    \* number of co-fiber iterations the harness expects
    SafetyBound,       \* drain iteration count beyond which co-fiber must
                       \* have made some progress
    MaxDrainIters      \* hard cap on drain_iters to keep TLC's state space
                       \* finite. Must be > SafetyBound so the buggy spec
                       \* can reach the invariant-violating state.

VARIABLES
    drain_state,   \* "running" | "yielded"
    co_progress,   \* 0 .. TargetProgress
    drain_iters    \* 0 .. MaxDrainIters (bounded for finite model checking)

vars == <<drain_state, co_progress, drain_iters>>

Init ==
    /\ drain_state  = "running"
    /\ co_progress  = 0
    /\ drain_iters  = 0

\* ── Clean drain fiber ────────────────────────────────────────

\* The drain body executes one iteration and then yields. This
\* corresponds to [Eio.Time.sleep clock drain_interval_s] at the end
\* of the loop body.
DrainIterAndYield ==
    /\ drain_state  = "running"
    /\ drain_iters  < MaxDrainIters
    /\ drain_state' = "yielded"
    /\ drain_iters' = drain_iters + 1
    /\ UNCHANGED co_progress

\* When the drain fiber's sleep elapses, the scheduler resumes it.
\* The co-fiber must have had a chance to run in between (CoFiberStep).
DrainResume ==
    /\ drain_state  = "yielded"
    /\ co_progress  > 0           \* progress is observed before drain re-runs
    /\ drain_state' = "running"
    /\ UNCHANGED <<co_progress, drain_iters>>

\* ── Buggy drain fiber ────────────────────────────────────────

\* The drain body recurses without yielding. drain_state stays
\* "running"; the scheduler has no opportunity to switch fibers.
DrainSpinNoYield ==
    /\ drain_state  = "running"
    /\ drain_iters  < MaxDrainIters
    /\ drain_state' = "running"
    /\ drain_iters' = drain_iters + 1
    /\ UNCHANGED co_progress

\* ── Co-located fiber ─────────────────────────────────────────

\* The co-located fiber can step only when the drain fiber has
\* yielded the domain.
CoFiberStep ==
    /\ drain_state = "yielded"
    /\ co_progress < TargetProgress
    /\ co_progress' = co_progress + 1
    /\ UNCHANGED <<drain_state, drain_iters>>

\* Stutter once the co-fiber has reached its target. Avoids TLC
\* deadlock errors at the natural terminal state.
CoFiberDone ==
    /\ co_progress = TargetProgress
    /\ UNCHANGED vars

\* ── Spec variants ────────────────────────────────────────────

NextClean ==
    \/ DrainIterAndYield
    \/ DrainResume
    \/ CoFiberStep
    \/ CoFiberDone

NextBuggy ==
    \/ DrainSpinNoYield
    \/ CoFiberStep            \* enabled in theory but drain_state never
                              \* becomes "yielded", so this branch never
                              \* fires under NextBuggy
    \/ CoFiberDone

SpecClean == Init /\ [][NextClean]_vars
SpecBuggy == Init /\ [][NextBuggy]_vars

\* ── Safety invariant ─────────────────────────────────────────

\* If drain has run more than SafetyBound times, co_progress must be
\* nonzero. Equivalent to "the drain fiber cannot starve the co-fiber
\* indefinitely". Holds under NextClean (DrainResume requires
\* co_progress > 0, which forces a CoFiberStep before the drain can
\* iterate again past the very first cycle). Violated under NextBuggy
\* once drain_iters exceeds SafetyBound.
NoStarvation ==
    ~ (drain_iters > SafetyBound /\ co_progress = 0)

\* ── Type invariant (defensive) ───────────────────────────────

TypeOK ==
    /\ drain_state \in {"running", "yielded"}
    /\ co_progress \in 0 .. TargetProgress
    /\ drain_iters \in 0 .. MaxDrainIters

====
