---- MODULE DispatchCoverage ----
\* Bug Model: FSM Event Dispatch Coverage for Data-Layer Clearing Actions.
\*
\* Bug class: "Code clears a blocking condition at the data layer but
\* forgets to dispatch the corresponding FSM event."
\*
\* Real-world instance (Bug #1, #6801): maybe_recover_from_failing() in
\* keeper_keepalive.ml:812-824 called Keeper_manual_reconcile.clear (data)
\* but did NOT dispatch Manual_reconcile_cleared to the FSM. Result:
\* derive_phase() stayed in Failing because conditions.manual_reconcile_required
\* was never set to FALSE, even though the blocking file was deleted.
\*
\* This spec models 5 blocking conditions from the keeper FSM
\* (keeper_state_machine.ml). Each has a "data layer" boolean and an
\* "FSM condition" boolean. A clearing action MUST set both to FALSE
\* atomically (within 1 step). The buggy variant omits the FSM dispatch.
\*
\* ── Mapped clearing actions (from OCaml code) ──
\*
\*  # | Data clear             | FSM event                  | OCaml location
\*  --+------------------------+----------------------------+--------------------------------
\*  1 | manual_reconcile file  | Manual_reconcile_cleared   | keeper_keepalive.ml:813-825
\*  2 | turn_failures counter  | Turn_succeeded             | keeper_keepalive.ml:804,1447
\*  3 | compaction_active flag  | Compaction_completed       | keeper_exec_context.ml:150
\*  4 | handoff_active flag     | Handoff_completed          | keeper_exec_context.ml:166
\*  5 | guardrail measurement  | Context_measured(stop=F)   | keeper_keepalive.ml:614-627
\*
\* ── Abstraction ──
\* Each blocking condition is modeled as a pair: (data_blocked, fsm_blocked).
\* Setting a blocker sets both to TRUE. A correct clear sets both to FALSE.
\* A buggy clear sets data_blocked=FALSE but leaves fsm_blocked=TRUE.
\* derive_phase uses fsm_blocked, so the keeper stays stuck.

EXTENDS Naturals

CONSTANTS
    Blockers  \* Set of blocker names, e.g. {"reconcile", "turn", "compact", "handoff", "guardrail"}

VARIABLES
    data_blocked,   \* [Blockers -> BOOLEAN] : data-layer state
    fsm_blocked,    \* [Blockers -> BOOLEAN] : FSM conditions record
    phase           \* "running" | "failing" : simplified derive_phase output

vars == <<data_blocked, fsm_blocked, phase>>

\* ── Type invariant ──

TypeOK ==
    /\ data_blocked \in [Blockers -> BOOLEAN]
    /\ fsm_blocked  \in [Blockers -> BOOLEAN]
    /\ phase \in {"running", "failing"}

\* ── Derived phase (mirrors derive_phase in keeper_state_machine.ml) ──
\* If ANY fsm_blocked condition is TRUE, phase is "failing".
\* Otherwise phase is "running".

DerivePhase(fsm) ==
    IF \E b \in Blockers : fsm[b] = TRUE
    THEN "failing"
    ELSE "running"

\* ── Init ──

Init ==
    /\ data_blocked = [b \in Blockers |-> FALSE]
    /\ fsm_blocked  = [b \in Blockers |-> FALSE]
    /\ phase = "running"

\* ── Actions ──

\* Set a blocker: both data and FSM layers agree.
SetBlocker(b) ==
    /\ data_blocked[b] = FALSE
    /\ data_blocked' = [data_blocked EXCEPT ![b] = TRUE]
    /\ fsm_blocked'  = [fsm_blocked  EXCEPT ![b] = TRUE]
    /\ phase' = DerivePhase(fsm_blocked')

\* Correct clear: clears BOTH data and FSM in one step.
CorrectClear(b) ==
    /\ data_blocked[b] = TRUE
    /\ data_blocked' = [data_blocked EXCEPT ![b] = FALSE]
    /\ fsm_blocked'  = [fsm_blocked  EXCEPT ![b] = FALSE]
    /\ phase' = DerivePhase(fsm_blocked')

\* ── Clean Next (all clears are correct) ──

Next ==
    \E b \in Blockers :
        \/ SetBlocker(b)
        \/ CorrectClear(b)

Spec == Init /\ [][Next]_vars

\* ── Safety Invariants ──

\* CORE INVARIANT: If data says "not blocked" then FSM must also say
\* "not blocked". This is the dispatch coverage contract.
\* Violation means: data was cleared but FSM event was not dispatched.

DataFsmConsistent ==
    \A b \in Blockers :
        data_blocked[b] = FALSE => fsm_blocked[b] = FALSE

\* DERIVED INVARIANT: Phase must agree with FSM conditions.
\* (This is a consistency check on DerivePhase.)

PhaseConsistent ==
    phase = DerivePhase(fsm_blocked)

\* STUCK DETECTION: A keeper is "stuck in Failing" if phase="failing"
\* but ALL data blockers are cleared. This is the observable symptom
\* of the bug class.

NeverStuckFailing ==
    (phase = "failing") =>
        (\E b \in Blockers : data_blocked[b] = TRUE)

\* ── Bug Model: one blocker omits FSM dispatch ──
\* The buggy clear sets data_blocked=FALSE but does NOT touch fsm_blocked.
\* This models the exact bug from keeper_keepalive.ml:812 where
\* Keeper_manual_reconcile.clear was called without Manual_reconcile_cleared.

BuggyClear(b) ==
    /\ data_blocked[b] = TRUE
    /\ data_blocked' = [data_blocked EXCEPT ![b] = FALSE]
    /\ UNCHANGED fsm_blocked   \* BUG: forgot to dispatch FSM event
    /\ phase' = DerivePhase(fsm_blocked')

NextBuggy ==
    \E b \in Blockers :
        \/ SetBlocker(b)
        \/ CorrectClear(b)
        \/ BuggyClear(b)

SpecBuggy == Init /\ [][NextBuggy]_vars

====
