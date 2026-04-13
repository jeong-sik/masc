---- MODULE KeeperRecoveryOrchestration ----
\* Cross-domain boundary spec: State (data layer) x FSM (condition layer).
\*
\* Models the maybe_recover_from_failing multi-event sequence in
\* keeper_keepalive.ml:774-836. This function clears the filesystem
\* reconcile record AND dispatches FSM events. Bug #1 (PR #6834) was
\* caused by clearing the data record without dispatching
\* Manual_reconcile_cleared to the FSM, leaving the keeper stuck in
\* Failing indefinitely.
\*
\* The spec captures the two-store consistency requirement: the data
\* layer (filesystem JSON) and the FSM condition layer (in-memory
\* conditions.manual_reconcile_required) must stay synchronized.
\*
\* Domain boundary: lib/keeper/keeper_manual_reconcile.ml (data) x
\*                  lib/keeper/keeper_state_machine.ml (FSM conditions)
\* Orchestrator:    lib/keeper/keeper_keepalive.ml (recovery sequence)

EXTENDS Naturals

VARIABLES
    \* Data layer (filesystem)
    data_reconcile_pending,     \* TRUE if reconcile record exists on disk
    \* FSM condition layer (in-memory)
    fsm_manual_reconcile,       \* TRUE if conditions.manual_reconcile_required
    fsm_turn_healthy,           \* TRUE if conditions.turn_healthy
    fsm_heartbeat_healthy       \* TRUE if conditions.heartbeat_healthy

vars == <<data_reconcile_pending, fsm_manual_reconcile, fsm_turn_healthy,
          fsm_heartbeat_healthy>>

\* Simplified derive_phase: Failing when any condition is unhealthy.
DerivePhase(mr, th, hh) ==
    IF mr \/ ~th \/ ~hh THEN "failing" ELSE "running"

Phase == DerivePhase(fsm_manual_reconcile, fsm_turn_healthy, fsm_heartbeat_healthy)

TypeOK ==
    /\ data_reconcile_pending \in BOOLEAN
    /\ fsm_manual_reconcile \in BOOLEAN
    /\ fsm_turn_healthy \in BOOLEAN
    /\ fsm_heartbeat_healthy \in BOOLEAN

\* ---- Init ----

Init ==
    /\ data_reconcile_pending = TRUE    \* reconcile record exists
    /\ fsm_manual_reconcile = TRUE      \* FSM knows about it
    /\ fsm_turn_healthy = FALSE         \* turn was unhealthy (triggered failing)
    /\ fsm_heartbeat_healthy = FALSE    \* heartbeat was unhealthy

\* ---- Environment Actions ----

\* A turn fails, setting data_reconcile_pending and fsm conditions.
TurnFails ==
    /\ Phase = "running"
    /\ data_reconcile_pending' = TRUE
    /\ fsm_manual_reconcile' = TRUE
    /\ fsm_turn_healthy' = FALSE
    /\ fsm_heartbeat_healthy' = fsm_heartbeat_healthy

\* ---- Recovery Sequence Actions (the orchestrator) ----

\* Step 1: Clear the filesystem data record.
\* Maps to: Keeper_manual_reconcile.clear(...)
ClearDataRecord ==
    /\ Phase = "failing"
    /\ data_reconcile_pending = TRUE
    /\ data_reconcile_pending' = FALSE
    /\ UNCHANGED <<fsm_manual_reconcile, fsm_turn_healthy, fsm_heartbeat_healthy>>

\* Step 2: Dispatch Heartbeat_ok to FSM.
\* Maps to: Keeper_state_machine.dispatch ~event:Heartbeat_ok
DispatchHeartbeatOk ==
    /\ Phase = "failing"
    /\ ~fsm_heartbeat_healthy
    /\ fsm_heartbeat_healthy' = TRUE
    /\ UNCHANGED <<data_reconcile_pending, fsm_manual_reconcile, fsm_turn_healthy>>

\* Step 3: Dispatch Manual_reconcile_cleared to FSM.
\* Maps to: Keeper_state_machine.dispatch ~event:Manual_reconcile_cleared
\* This is the action that was MISSING in the buggy code (PR #6834).
DispatchManualReconcileCleared ==
    /\ fsm_manual_reconcile = TRUE
    /\ fsm_manual_reconcile' = FALSE
    /\ UNCHANGED <<data_reconcile_pending, fsm_turn_healthy, fsm_heartbeat_healthy>>

\* Step 4: Dispatch Turn_succeeded to FSM.
\* Maps to: Keeper_state_machine.dispatch ~event:Turn_succeeded
\* Note: Turn_succeeded clears turn_healthy only, NOT manual_reconcile.
\* This matches the OCaml code (keeper_state_machine.ml:311-312).
DispatchTurnSucceeded ==
    /\ Phase = "failing"
    /\ ~fsm_turn_healthy
    /\ fsm_turn_healthy' = TRUE
    \* Turn_succeeded does NOT clear manual_reconcile (this is the
    \* correct OCaml behavior, and the divergence from the old TLA+ spec).
    /\ UNCHANGED <<data_reconcile_pending, fsm_manual_reconcile, fsm_heartbeat_healthy>>

\* ---- Clean Next ----

Next ==
    \/ TurnFails
    \/ ClearDataRecord
    \/ DispatchHeartbeatOk
    \/ DispatchManualReconcileCleared
    \/ DispatchTurnSucceeded

\* Fairness: each recovery action individually must eventually fire when
\* continuously enabled. WF on the disjunction alone is insufficient
\* because TLC can satisfy it by repeatedly choosing one enabled disjunct
\* while starving another.
Fairness ==
    /\ WF_vars(ClearDataRecord)
    /\ WF_vars(DispatchHeartbeatOk)
    /\ WF_vars(DispatchManualReconcileCleared)
    /\ WF_vars(DispatchTurnSucceeded)

Spec == Init /\ [][Next]_vars /\ Fairness

\* ---- Safety Invariants ----

\* S1: Phase derivation is consistent with conditions.
PhaseConsistent ==
    Phase \in {"running", "failing"}

\* S2: If phase is running, no reconcile is pending in FSM.
RunningMeansNoReconcile ==
    Phase = "running" => ~fsm_manual_reconcile

\* S3: Data and FSM layers are directionally consistent: if data is
\* cleared, the FSM clearing path must be available (fsm_manual_reconcile
\* can still be true temporarily, but the system must not be stuck).
\* This is captured by liveness, not as an invariant, because the
\* data clearing and FSM dispatch are separate steps.

\* Combined safety
SafetyInvariant ==
    /\ TypeOK
    /\ RunningMeansNoReconcile

\* ---- Liveness Properties ----

\* L1: manual_reconcile_required eventually clears (the one-way trap
\* property that Bug #1 violated).
ReconcileEventuallyClears ==
    fsm_manual_reconcile ~> ~fsm_manual_reconcile

\* L2: The keeper eventually reaches running.
EventuallyRunning ==
    Phase = "failing" ~> Phase = "running"

\* ---- Bug Model: omit DispatchManualReconcileCleared ----
\*
\* This models the exact bug from PR #6834: the recovery sequence
\* clears the data record and dispatches Heartbeat_ok and Turn_succeeded,
\* but forgets to dispatch Manual_reconcile_cleared. The FSM condition
\* manual_reconcile_required stays true, phase stays "failing".

NextBuggy ==
    \/ TurnFails
    \/ ClearDataRecord
    \/ DispatchHeartbeatOk
    \* DispatchManualReconcileCleared is OMITTED (the bug)
    \/ DispatchTurnSucceeded

FairnessBuggy ==
    /\ WF_vars(ClearDataRecord)
    /\ WF_vars(DispatchHeartbeatOk)
    /\ WF_vars(DispatchTurnSucceeded)

SpecBuggy == Init /\ [][NextBuggy]_vars /\ FairnessBuggy

====
