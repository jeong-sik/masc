---- MODULE KeeperTaskAcquisition ----
\* Task acquisition control flow for [lib/keeper/keeper_unified_turn.ml]
\* [run_keeper_cycle] (line 1042+).
\*
\* The OCaml runtime composes task acquisition out of three pieces:
\*   1. Producers (operator, supervisor, autoresearch, board posts)
\*      append tasks to the backlog observable from
\*      [Keeper_world_observation].
\*   2. The keepalive fiber synthesises a [world_observation] for the
\*      next cycle and hands it to [run_keeper_cycle].
\*   3. [run_keeper_cycle] picks an actionable item from that
\*      observation, transitions the keeper to "running", drives the
\*      turn, and returns the keeper to idle.
\*
\* This spec collapses that pipeline into the abstract claim-and-finish
\* behaviour relevant to safety: every task that is *claimed* must
\* eventually be *finished*. A claim that is silently dropped without
\* a finish is what the boundary critique called a "task acquisition
\* black box" — visible as a queue that drains while no work shows up
\* in the keeper transition audit.
\*
\* Cycle 8 / Tier B2 of the Kimi keeper FSM review plan.
\*
\* Bug-Model contract (CLAUDE.md software-development.md):
\*   Spec      under KeeperTaskAcquisition.cfg       => TLC: no error.
\*   SpecBuggy under KeeperTaskAcquisition-buggy.cfg => TLC: invariant
\*                                                     violated.
\* Both must hold.

EXTENDS Naturals

CONSTANTS
    MaxTasks   \* upper bound on submitted tasks (state-space cap)

ASSUME MaxTasksNat == MaxTasks \in Nat /\ MaxTasks >= 2

VARIABLES
    queue_depth,          \* tasks waiting in the backlog
    turn_state,           \* "idle" | "running"
    tasks_claimed,        \* total AssignTask invocations
    tasks_completed       \* total TurnComplete invocations

vars == << queue_depth, turn_state, tasks_claimed, tasks_completed >>

TypeOK ==
    /\ queue_depth     \in 0..MaxTasks
    /\ turn_state      \in {"idle", "running"}
    /\ tasks_claimed   \in 0..MaxTasks
    /\ tasks_completed \in 0..MaxTasks

Init ==
    /\ queue_depth     = 0
    /\ turn_state      = "idle"
    /\ tasks_claimed   = 0
    /\ tasks_completed = 0

\* ── Honest actions ─────────────────────────────────────────────

\* External producer (operator / supervisor / autoresearch / board)
\* appends a task to the backlog. Bounded by MaxTasks so TLC has a
\* finite reachable state space.
SubmitTask ==
    /\ queue_depth < MaxTasks
    /\ queue_depth' = queue_depth + 1
    /\ UNCHANGED << turn_state, tasks_claimed, tasks_completed >>

\* The keepalive fiber observes a non-empty backlog while the keeper
\* is idle and dispatches [run_keeper_cycle] with a world_observation
\* that names a concrete task. The [tasks_claimed < MaxTasks] guard
\* keeps the bounded run finite — TLC otherwise wraps queue cycles
\* around forever.
AssignTask ==
    /\ queue_depth > 0
    /\ turn_state = "idle"
    /\ tasks_claimed < MaxTasks
    /\ queue_depth' = queue_depth - 1
    /\ turn_state' = "running"
    /\ tasks_claimed' = tasks_claimed + 1
    /\ UNCHANGED tasks_completed

\* The turn finishes; the claimed task is recorded as done. The
\* counters move in lockstep, so the invariants below stay tight.
TurnComplete ==
    /\ turn_state = "running"
    /\ turn_state' = "idle"
    /\ tasks_completed' = tasks_completed + 1
    /\ UNCHANGED << queue_depth, tasks_claimed >>

\* Idle keeper observes an empty queue. Stutter — nothing to do.
EmptyQueueSleep ==
    /\ queue_depth = 0
    /\ turn_state = "idle"
    /\ UNCHANGED vars

\* Stutter step so TLC does not flag deadlock in the absorbing
\* states. Two cases enable stutter:
\*   - (queue=0, idle, claimed=completed): everything is reconciled,
\*     no work to do.
\*   - (claimed=MaxTasks, idle, completed=claimed): we have hit the
\*     bounded-run saturation point; no further AssignTask is
\*     possible, but the trailing queue items remain a legitimate
\*     state (in production they would be consumed in the next run).
Done ==
    /\ turn_state = "idle"
    /\ tasks_claimed = tasks_completed
    /\ (queue_depth = 0 \/ tasks_claimed = MaxTasks)
    /\ UNCHANGED vars

\* ── Bug action (only in SpecBuggy) ─────────────────────────────

\* Models the "task rejected" failure: the keeper claims a task
\* (decrementing the queue and bumping tasks_claimed) but never
\* completes it. In the OCaml runtime this maps to paths where
\* [run_keeper_cycle] returns Ok meta on a non-executable phase or a
\* livelock-blocked turn — the queue moved but the audit trail does
\* not show a corresponding completion.
\*
\* The action drops the keeper back to idle without bumping
\* tasks_completed. The counter mismatch makes the failure visible
\* to the safety invariants below.
TaskRejected ==
    /\ queue_depth > 0
    /\ turn_state = "idle"
    /\ tasks_claimed < MaxTasks
    /\ queue_depth' = queue_depth - 1
    /\ tasks_claimed' = tasks_claimed + 1
    /\ UNCHANGED << turn_state, tasks_completed >>   \* finishes never

\* ── Spec wirings ───────────────────────────────────────────────

Next ==
    \/ SubmitTask
    \/ AssignTask
    \/ TurnComplete
    \/ EmptyQueueSleep
    \/ Done

NextBuggy == Next \/ TaskRejected

Spec      == Init /\ [][Next]_vars
SpecBuggy == Init /\ [][NextBuggy]_vars

\* ── Safety invariants ─────────────────────────────────────────

\* Core safety: at most one task is in flight at a time. Under the
\* clean Next, tasks_claimed bumps only via AssignTask which also
\* sets turn_state to "running"; TurnComplete bumps tasks_completed
\* and returns to idle. Therefore tasks_claimed - tasks_completed is
\* either 0 (idle, no in-flight) or 1 (running, one in-flight).
NoTaskOrphan ==
    tasks_claimed - tasks_completed <= 1

\* Quiescent state must be fully reconciled: when the queue is empty
\* and the keeper is idle, every claimed task must have been
\* completed. TaskRejected violates this — after the bug, the keeper
\* returns to idle with an empty queue but tasks_claimed >
\* tasks_completed. This is the silent-state form of the bug.
QuiescentImpliesCompleted ==
    (queue_depth = 0 /\ turn_state = "idle")
        => tasks_claimed = tasks_completed

\* In-flight accounting must match the FSM: a "running" keeper has
\* exactly one outstanding claim; an "idle" keeper has none. This
\* catches a different shape of the bug where the keeper goes
\* "running" without bumping tasks_claimed, or returns to "idle"
\* without bumping tasks_completed.
InFlightMatchesFSM ==
    /\ (turn_state = "running") => (tasks_claimed - tasks_completed = 1)
    /\ (turn_state = "idle")    => (tasks_claimed - tasks_completed = 0)

SafetyInvariant ==
    /\ NoTaskOrphan
    /\ QuiescentImpliesCompleted
    /\ InFlightMatchesFSM

====
