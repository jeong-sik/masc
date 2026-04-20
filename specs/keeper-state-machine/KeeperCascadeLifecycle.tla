---- MODULE KeeperCascadeLifecycle ----
\* Keeper-facing cascade lifecycle projection.
\*
\* This spec models the live cascade lane stored in
\* [Keeper_registry.current_turn_observation]. It is deliberately narrower
\* than provider-level routing: the runtime persists only the keeper-facing
\* turn projection, not the full candidate/provider attempt graph.
\*
\* Authoritative write points (lib/keeper/keeper_registry.ml):
\*   - mark_turn_started                       line 386
\*   - mark_turn_measurement                   line 404
\*   - set_turn_decision_stage                 line 420
\*   - set_turn_cascade_state                  line 424
\*   - set_turn_selected_model                 line 437
\*   - prepare_turn_retry_after_compaction     line 441
\*   - mark_turn_gate_rejected_by_name         line 452
\*   - mark_turn_finished                      line 472
\*
\* OCaml ↔ TLA+ mapping (see #8642 family):
\*
\*   spec variable      | OCaml type variant                  | source
\*   -------------------+-------------------------------------+--------
\*   turn_phase         | type turn_phase = Turn_idle |       | lib/keeper/keeper_registry.ml:63-68
\*                      |   Turn_prompting | Turn_executing | |
\*                      |   Turn_compacting | Turn_finalizing |
\*   decision_stage     | type decision_stage =               | lib/keeper/keeper_registry.ml:70-74
\*                      |   Decision_undecided |              |
\*                      |   Decision_guard_ok |               |
\*                      |   Decision_gate_rejected |          |
\*                      |   Decision_tool_policy_selected     |
\*   cascade_state      | type cascade_state = Cascade_idle | | lib/keeper/keeper_registry.ml:76-81
\*                      |   Cascade_selecting | Cascade_trying|
\*                      |   Cascade_done | Cascade_exhausted  |
\*   turn_live          | current_turn_observation = Some _   | record field on keeper_runtime
\*
\* Scope projection: spec models the keeper-facing turn projection
\* only — the full candidate/provider attempt graph (Llm_provider /
\* cascade_runtime cycle) is intentionally OUT OF SCOPE here.
\* Adding a new provider attempt outcome does NOT require updating
\* this spec; adding a new turn_phase / decision_stage / cascade_state
\* constructor DOES require updating the corresponding spec
\* PhaseSet / DecisionStageSet / CascadeStateSet constants.

EXTENDS TLC

VARIABLES
    turn_live,
    turn_phase,
    decision_stage,
    cascade_state,
    measurement_bound,
    selected_model_bound

vars ==
    << turn_live, turn_phase, decision_stage, cascade_state,
       measurement_bound, selected_model_bound >>

TurnPhaseSet == {"idle", "prompting", "executing", "compacting", "finalizing"}
DecisionSet  == {"undecided", "guard_ok", "gate_rejected", "tool_policy_selected"}
CascadeSet   == {"idle", "selecting", "trying", "done", "exhausted"}
ActionSet    == {
    "StartTurn",
    "BindMeasurement",
    "GuardOk",
    "SelectToolPolicy",
    "CascadeTrying",
    "GateRejected",
    "CascadeDone",
    "CascadeExhausted",
    "EnterCompacting",
    "RetryAfterCompaction",
    "FinishTurn"
}
InvariantSet == {
    "NoLiveTurnClearsCascade",
    "CascadeSelectionRequiresMeasurement",
    "SelectingRequiresToolPolicy",
    "TryingRequiresLiveAttempt",
    "GateRejectedPreservesTrying",
    "TerminalCascadeRequiresFinalizing",
    "CompactingRequiresTrying"
}

TypeOK ==
    /\ turn_live \in BOOLEAN
    /\ turn_phase \in TurnPhaseSet
    /\ decision_stage \in DecisionSet
    /\ cascade_state \in CascadeSet
    /\ measurement_bound \in BOOLEAN
    /\ selected_model_bound \in BOOLEAN

Init ==
    /\ turn_live = FALSE
    /\ turn_phase = "idle"
    /\ decision_stage = "undecided"
    /\ cascade_state = "idle"
    /\ measurement_bound = FALSE
    /\ selected_model_bound = FALSE

StartTurn ==
    /\ ~turn_live
    /\ turn_live' = TRUE
    /\ turn_phase' = "prompting"
    /\ decision_stage' = "undecided"
    /\ cascade_state' = "idle"
    /\ measurement_bound' = FALSE
    /\ selected_model_bound' = FALSE

BindMeasurement ==
    /\ turn_live
    /\ turn_phase = "prompting"
    /\ decision_stage = "undecided"
    /\ cascade_state = "idle"
    /\ ~measurement_bound
    /\ measurement_bound' = TRUE
    /\ UNCHANGED <<turn_live, turn_phase, decision_stage,
                    cascade_state, selected_model_bound>>

GuardOk ==
    /\ turn_live
    /\ turn_phase = "prompting"
    /\ measurement_bound
    /\ decision_stage = "undecided"
    /\ decision_stage' = "guard_ok"
    /\ UNCHANGED <<turn_live, turn_phase, cascade_state,
                    measurement_bound, selected_model_bound>>

SelectToolPolicy ==
    /\ turn_live
    /\ turn_phase = "prompting"
    /\ cascade_state = "idle"
    /\ measurement_bound
    /\ decision_stage \in {"undecided", "guard_ok"}
    /\ decision_stage' = "tool_policy_selected"
    /\ cascade_state' = "selecting"
    /\ UNCHANGED <<turn_live, turn_phase, measurement_bound,
                    selected_model_bound>>

CascadeTrying ==
    /\ turn_live
    /\ turn_phase = "prompting"
    /\ decision_stage = "tool_policy_selected"
    /\ cascade_state = "selecting"
    /\ measurement_bound
    /\ turn_phase' = "executing"
    /\ cascade_state' = "trying"
    /\ UNCHANGED <<turn_live, decision_stage, measurement_bound,
                    selected_model_bound>>

GateRejected ==
    /\ turn_live
    /\ turn_phase = "executing"
    /\ decision_stage = "tool_policy_selected"
    /\ cascade_state = "trying"
    /\ turn_phase' = "finalizing"
    /\ decision_stage' = "gate_rejected"
    /\ UNCHANGED <<turn_live, cascade_state, measurement_bound,
                    selected_model_bound>>

CascadeDone ==
    /\ turn_live
    /\ turn_phase = "executing"
    /\ cascade_state = "trying"
    /\ turn_phase' = "finalizing"
    /\ cascade_state' = "done"
    /\ selected_model_bound' = TRUE
    /\ UNCHANGED <<turn_live, decision_stage, measurement_bound>>

CascadeExhausted ==
    /\ turn_live
    /\ turn_phase = "executing"
    /\ cascade_state = "trying"
    /\ turn_phase' = "finalizing"
    /\ cascade_state' = "exhausted"
    /\ UNCHANGED <<turn_live, decision_stage, measurement_bound,
                    selected_model_bound>>

EnterCompacting ==
    /\ turn_live
    /\ turn_phase = "executing"
    /\ cascade_state = "trying"
    /\ turn_phase' = "compacting"
    /\ UNCHANGED <<turn_live, decision_stage, cascade_state,
                    measurement_bound, selected_model_bound>>

RetryAfterCompaction ==
    /\ turn_live
    /\ turn_phase = "compacting"
    /\ cascade_state = "trying"
    /\ turn_phase' = "prompting"
    /\ decision_stage' = "guard_ok"
    /\ cascade_state' = "idle"
    /\ selected_model_bound' = FALSE
    /\ UNCHANGED <<turn_live, measurement_bound>>

FinishTurn ==
    /\ turn_live
    /\ turn_phase \in (TurnPhaseSet \ {"idle"})
    /\ turn_live' = FALSE
    /\ turn_phase' = "idle"
    /\ decision_stage' = "undecided"
    /\ cascade_state' = "idle"
    /\ measurement_bound' = FALSE
    /\ selected_model_bound' = FALSE

Next ==
    \/ StartTurn
    \/ BindMeasurement
    \/ GuardOk
    \/ SelectToolPolicy
    \/ CascadeTrying
    \/ GateRejected
    \/ CascadeDone
    \/ CascadeExhausted
    \/ EnterCompacting
    \/ RetryAfterCompaction
    \/ FinishTurn

Fairness ==
    /\ WF_vars(GateRejected)
    /\ WF_vars(CascadeDone)
    /\ WF_vars(CascadeExhausted)
    /\ WF_vars(RetryAfterCompaction)
    /\ WF_vars(FinishTurn)

Spec == Init /\ [][Next]_vars /\ Fairness

NoLiveTurnClearsCascade ==
    ~turn_live =>
        /\ turn_phase = "idle"
        /\ decision_stage = "undecided"
        /\ cascade_state = "idle"
        /\ ~measurement_bound
        /\ ~selected_model_bound

CascadeSelectionRequiresMeasurement ==
    cascade_state \in {"selecting", "trying", "done", "exhausted"} =>
        /\ turn_live
        /\ measurement_bound

SelectingRequiresToolPolicy ==
    cascade_state = "selecting" =>
        /\ turn_live
        /\ turn_phase = "prompting"
        /\ decision_stage = "tool_policy_selected"

TryingRequiresLiveAttempt ==
    cascade_state = "trying" =>
        /\ turn_live
        /\ turn_phase \in {"executing", "compacting", "finalizing"}
        /\ decision_stage \in {"tool_policy_selected", "gate_rejected"}
        /\ measurement_bound

GateRejectedPreservesTrying ==
    decision_stage = "gate_rejected" =>
        /\ turn_live
        /\ turn_phase = "finalizing"
        /\ cascade_state = "trying"

TerminalCascadeRequiresFinalizing ==
    cascade_state \in {"done", "exhausted"} =>
        /\ turn_live
        /\ turn_phase = "finalizing"
        /\ decision_stage = "tool_policy_selected"

CompactingRequiresTrying ==
    turn_phase = "compacting" =>
        /\ turn_live
        /\ cascade_state = "trying"
        /\ decision_stage = "tool_policy_selected"

Safety ==
    /\ TypeOK
    /\ NoLiveTurnClearsCascade
    /\ CascadeSelectionRequiresMeasurement
    /\ SelectingRequiresToolPolicy
    /\ TryingRequiresLiveAttempt
    /\ GateRejectedPreservesTrying
    /\ TerminalCascadeRequiresFinalizing
    /\ CompactingRequiresTrying

TryingEventuallyTerminates ==
    (cascade_state = "trying") ~> (cascade_state /= "trying")

FinalizingEventuallyClears ==
    (turn_phase = "finalizing") ~> (turn_phase = "idle")

BugCascadeBeforeMeasurement ==
    /\ turn_live
    /\ turn_phase = "prompting"
    /\ decision_stage = "undecided"
    /\ cascade_state = "idle"
    /\ ~measurement_bound
    /\ decision_stage' = "tool_policy_selected"
    /\ cascade_state' = "selecting"
    /\ UNCHANGED <<turn_live, turn_phase, measurement_bound,
                   selected_model_bound>>

SpecBuggy == Init /\ [][Next \/ BugCascadeBeforeMeasurement]_vars /\ Fairness

====
