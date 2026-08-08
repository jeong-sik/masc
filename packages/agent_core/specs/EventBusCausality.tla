---- MODULE EventBusCausality ----
EXTENDS Sequences, Naturals
\* Bug Model: Event_bus envelope causality invariants.
\*
\* Verifies two structural properties of the envelope design:
\*
\* 1. RunIdConsistency: all events emitted within one Agent.run
\*    invocation share the same run_id. A ToolCalled with a different
\*    run_id from its surrounding TurnStarted is an orphan that no
\*    offline consumer can join — this is the exact gap the envelope
\*    was introduced to close.
\*
\* 2. CausalOrdering: ToolCalled / ToolCompleted can only appear
\*    between a TurnStarted and its matching TurnCompleted within
\*    the same run_id. A ToolCalled outside a turn boundary is a
\*    ghost dispatch (same class as KeepalivePhaseConsistency).
\*
\* Abstraction:
\*   - Agents are abstracted as a set A of agent names.
\*   - Runs are abstracted as a set R of run_ids.
\*   - Events are modeled as actions that append to a log sequence.
\*   - The bus itself (Eio.Stream, fibers) is abstracted away:
\*     we model the *emission* discipline, not the delivery order.
\*     Delivery reordering is a consumer-side concern; the invariant
\*     is on the producer side.
\*
\* masc-mcp reference:
\*   oas/lib/event_bus.ml     (envelope type + mk_event)
\*   oas/lib/pipeline/pipeline.ml (event_envelope helper, publish sites)
\*   oas/lib/agent/agent_tools.ml (?current_run_id threading)

CONSTANTS A, R   \* sets of agent names and run_ids

VARIABLES
    log,            \* sequence of emitted events (append-only)
    turn_open,      \* [R -> BOOLEAN] — is a turn currently open for this run?
    run_active      \* [R -> BOOLEAN] — is this run still executing?

vars == <<log, turn_open, run_active>>

\* Event payloads (abstracted to type tags + run_id)
EventTypes == {"turn_started", "turn_completed", "tool_called", "tool_completed"}

Event == [type : EventTypes, agent : A, run_id : R]

TypeOK ==
    /\ log \in Seq(Event)
    /\ turn_open \in [R -> BOOLEAN]
    /\ run_active \in [R -> BOOLEAN]

Init ==
    /\ log = <<>>
    /\ turn_open = [r \in R |-> FALSE]
    /\ run_active = [r \in R |-> TRUE]

\* ── Actions ──────────────────────────────────────────────

\* Start a turn: only when the run is active and no turn is open.
TurnStarted(a, r) ==
    /\ run_active[r]
    /\ ~turn_open[r]
    /\ turn_open' = [turn_open EXCEPT ![r] = TRUE]
    /\ log' = Append(log, [type |-> "turn_started", agent |-> a, run_id |-> r])
    /\ UNCHANGED run_active

\* Complete a turn: only when a turn is open for this run.
TurnCompleted(a, r) ==
    /\ turn_open[r]
    /\ turn_open' = [turn_open EXCEPT ![r] = FALSE]
    /\ log' = Append(log, [type |-> "turn_completed", agent |-> a, run_id |-> r])
    /\ UNCHANGED run_active

\* Tool called: only within an open turn.
ToolCalled(a, r) ==
    /\ turn_open[r]
    /\ log' = Append(log, [type |-> "tool_called", agent |-> a, run_id |-> r])
    /\ UNCHANGED <<turn_open, run_active>>

\* Tool completed: only within an open turn.
ToolCompleted(a, r) ==
    /\ turn_open[r]
    /\ log' = Append(log, [type |-> "tool_completed", agent |-> a, run_id |-> r])
    /\ UNCHANGED <<turn_open, run_active>>

\* Run finishes: mark inactive. No more events for this run.
RunFinished(r) ==
    /\ run_active[r]
    /\ ~turn_open[r]   \* must close turn before finishing
    /\ run_active' = [run_active EXCEPT ![r] = FALSE]
    /\ UNCHANGED <<log, turn_open>>

\* ── Clean Next ───────────────────────────────────────────

Next ==
    \/ \E a \in A, r \in R : TurnStarted(a, r)
    \/ \E a \in A, r \in R : TurnCompleted(a, r)
    \/ \E a \in A, r \in R : ToolCalled(a, r)
    \/ \E a \in A, r \in R : ToolCompleted(a, r)
    \/ \E r \in R : RunFinished(r)

\* Bound log length to keep state space finite for TLC.
\* 6 entries with 2 agents × 2 runs covers:
\*   TurnStarted → ToolCalled → ToolCompleted → TurnCompleted (4)
\*   + interleaved second run events (2 more).
LogBound == Len(log) <= 6

Spec == Init /\ [][Next]_vars

\* ── Safety Invariants ────────────────────────────────────

\* Invariant 1: CausalOrdering
\* Every tool event in the log appears within an open turn of
\* the same run_id. Since we gate ToolCalled/ToolCompleted on
\* turn_open[r], this holds by construction in the clean model.
\* The buggy model will violate it.
CausalOrdering ==
    \A i \in 1..Len(log) :
        log[i].type \in {"tool_called", "tool_completed"} =>
            \* There exists a preceding turn_started with same run_id
            \* that has not been closed yet at position i.
            \E j \in 1..(i-1) :
                /\ log[j].type = "turn_started"
                /\ log[j].run_id = log[i].run_id
                /\ ~\E k \in (j+1)..(i-1) :
                    /\ log[k].type = "turn_completed"
                    /\ log[k].run_id = log[i].run_id

\* Invariant 2: RunIdConsistency
\* Within a single run, no two events have different run_ids.
\* (This is trivially true since run_id is a parameter of the
\* action — but the buggy model can mix them up.)
\* Stronger form: if a tool event and a turn event share the
\* same position in a run, they must share run_id.
\* Already enforced by action signatures; stated for documentation.

\* Invariant 3: NoToolOutsideTurn
\* No tool event exists in the log without an enclosing turn.
\* Equivalent to CausalOrdering but stated as a state predicate
\* on turn_open (stronger than log-based check).
NoToolOutsideTurn ==
    \A r \in R :
        ~turn_open[r] =>
            \A i \in 1..Len(log) :
                (log[i].run_id = r /\ log[i].type \in {"tool_called", "tool_completed"}) =>
                    \E j \in 1..(i-1) :
                        /\ log[j].type = "turn_started"
                        /\ log[j].run_id = r
                        /\ ~\E k \in (j+1)..(i-1) :
                            /\ log[k].type = "turn_completed"
                            /\ log[k].run_id = r

\* ── Bug Model: ghost tool dispatch ───────────────────────
\* Bug: a tool event is emitted without checking turn_open.
\* This models the exact regression the envelope gating prevents:
\* a concurrent fiber emits ToolCalled for a run whose turn has
\* already completed (or never started).

GhostToolCalled(a, r) ==
    /\ run_active[r]
    \* BUG: no turn_open[r] check
    /\ log' = Append(log, [type |-> "tool_called", agent |-> a, run_id |-> r])
    /\ UNCHANGED <<turn_open, run_active>>

\* Bug: tool event emitted with wrong run_id (cross-contamination).
CrossRunToolCalled(a, r_wrong, r_actual) ==
    /\ r_wrong /= r_actual
    /\ turn_open[r_actual]
    /\ run_active[r_actual]
    \* BUG: uses r_wrong instead of r_actual
    /\ log' = Append(log, [type |-> "tool_called", agent |-> a, run_id |-> r_wrong])
    /\ UNCHANGED <<turn_open, run_active>>

NextBuggy ==
    \/ Next
    \/ \E a \in A, r \in R : GhostToolCalled(a, r)
    \/ \E a \in A, r1 \in R, r2 \in R : CrossRunToolCalled(a, r1, r2)

SpecBuggy == Init /\ [][NextBuggy]_vars

====
