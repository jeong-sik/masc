---- MODULE KeeperDecisionPipeline ----
(***************************************************************************)
(* KeeperDecisionPipeline — runtime-aligned decision stage contract.       *)
(*                                                                         *)
(* This spec models the decision-stage projection stored in                *)
(* [Keeper_registry.current_turn_observation.decision_stage]. The current  *)
(* runtime no longer uses the old Thompson/tool_count feedback loop that   *)
(* an earlier TLA draft described. Instead, the live decision pipeline is  *)
(* a narrow per-turn contract driven by four write points:                 *)
(*   - mark_turn_started                    → undecided                    *)
(*   - mark_turn_measurement + guard pass   → guard_ok                     *)
(*   - keeper_agent_run tool disclosure     → tool_policy_selected         *)
(*   - keeper_guards override/approval gate → gate_rejected               *)
(* plus retry/finalize resets.                                              *)
(*                                                                         *)
(* OCaml <-> TLA+ mapping (see #8642 family):                              *)
(*                                                                         *)
(*   spec variable      | OCaml field / type                       | source *)
(*   -------------------+------------------------------------------+--------*)
(*   turn_live          | current_turn_observation = Some _        | record on keeper_runtime *)
(*   turn_phase         | type turn_phase = Turn_idle | ...        | lib/keeper/keeper_registry.ml — type turn_phase *)
(*   decision_stage     | type decision_stage = Decision_undecided | lib/keeper/keeper_registry.ml — type decision_stage *)
(*                      |   | Decision_guard_ok                    | (mli mirror at keeper_registry.mli -- type decision_stage_active) *)
(*                      |   | Decision_gate_rejected               | *)
(*                      |   | Decision_tool_policy_selected        | *)
(*   cascade_state      | type cascade_state = ...                 | lib/keeper/keeper_registry.ml — type cascade_state *)
(*   measurement_bound  | observation.measurement_bound : bool     | record on observation *)
(*                                                                         *)
(* Authoritative write points (lib/keeper/keeper_registry.ml).             *)
(* Cite by symbol -- iter 64 N-2.a (`*.ml` files grow; line refs drift on  *)
(* every edit while function names are stable identifiers). Verified       *)
(* against main as of 2026-05-12 (iter 93 line-ref drain; #11641 sibling   *)
(* refresh; iter 92 #14996 closed the `\.ml:NNN` colon-form guard).        *)
(*   - mark_turn_started                       -- Decision_undecided          *)
(*   - mark_turn_measurement                   -- sets measurement_bound      *)
(*   - set_turn_decision_stage                 -- Decision_guard_ok | _selected *)
(*   - prepare_turn_retry_after_compaction     -- reset to Decision_guard_ok   *)
(*   - mark_turn_gate_rejected_by_name         -- Decision_gate_rejected       *)
(*   - mark_turn_finished                      -- reset to Decision_undecided  *)
(*                                                                         *)
(* Variant exhaustiveness re-export                                         *)
(* (keeper_composite_observer.ml — `type decision_stage` re-export +        *)
(*  `all_decision_stages` list; cited by symbol, not line — iter 64 N-2.a,  *)
(*  converted in the iter 85 scattered-singles line-ref sweep):             *)
(*     `type decision_stage = Keeper_registry.decision_stage = ...`        *)
(*     `let all_decision_stages = [...]`                                    *)
(*   The re-export uses an EQUALITY type so any new constructor in the    *)
(*   registry forces a compile-time addition to the re-export AND to       *)
(*   all_decision_stages -- protecting the spec's DecisionSet enum from    *)
(*   runtime drift.                                                        *)
(*                                                                         *)
(* Scope projection: this spec is the per-turn DECISION lane only --       *)
(*   - sibling KeeperCascadeLifecycle covers cascade_state for the same    *)
(*     turn (selecting / trying / done / exhausted),                       *)
(*   - sibling KeeperConditionsGovernPhase covers the divergent-conditions *)
(*     handoff signal that runs orthogonally.                              *)
(*   The full keeper lifecycle FSM (Offline / Running / Crashed / etc.)    *)
(*   in lib/keeper/keeper_state_machine.ml is OUT OF SCOPE here.           *)
(*                                                                         *)
(* Spec evolution note: an earlier draft modelled a Thompson/tool_count    *)
(* feedback loop. The runtime no longer carries that information on the    *)
(* decision_stage variant -- adding new tool-policy variants does NOT      *)
(* require updating this spec UNLESS they introduce a new entry in the    *)
(* OCaml decision_stage type. Adding a new decision_stage CONSTRUCTOR     *)
(* DOES require updating DecisionSet here AND adding the corresponding     *)
(* gating condition (mirror GuardOkRequiresMeasurement / GateRejected-     *)
(* RequiresFinalizing).                                                    *)
(***************************************************************************)

VARIABLES
    turn_live,          \* current_turn_observation = Some _
    turn_phase,         \* Keeper_registry.turn_phase
    decision_stage,     \* Keeper_registry.decision_stage
    cascade_state,      \* Keeper_registry.cascade_state
    measurement_bound   \* mark_turn_measurement already consumed

vars == <<turn_live, turn_phase, decision_stage, cascade_state, measurement_bound>>

TurnPhaseSet == {"idle", "prompting", "routing", "executing", "compacting", "finalizing", "exhausted"}
DecisionSet  == {"undecided", "guard_ok", "gate_rejected", "tool_policy_selected"}
CascadeSet   == {"idle", "selecting", "trying", "done", "exhausted"}
ActionSet    == {
    "StartTurn",
    "BindMeasurement",
    "GuardOk",
    "SelectToolPolicy",
    "CascadeTrying",
    "GateRejected",
    "RetryAfterCompaction",
    "FinishTurn"
}
InvariantSet == {
    "NoLiveTurnClearsDecision",
    "IdleRequiresUndecided",
    "GuardOkRequiresMeasurement",
    "DecisionBoundaryRequiresMeasurement",
    "GateRejectedRequiresFinalizing",
    "NonIdleCascadeRequiresDecisionBoundary",
    "SelectingRequiresPrompting"
}

TypeOK ==
    /\ turn_live \in BOOLEAN
    /\ turn_phase \in TurnPhaseSet
    /\ decision_stage \in DecisionSet
    /\ cascade_state \in CascadeSet
    /\ measurement_bound \in BOOLEAN

Init ==
    /\ turn_live = FALSE
    /\ turn_phase = "idle"
    /\ decision_stage = "undecided"
    /\ cascade_state = "idle"
    /\ measurement_bound = FALSE

StartTurn ==
    /\ ~turn_live
    /\ turn_live' = TRUE
    /\ turn_phase' = "prompting"
    /\ decision_stage' = "undecided"
    /\ cascade_state' = "idle"
    /\ measurement_bound' = FALSE

BindMeasurement ==
    /\ turn_live
    /\ turn_phase = "prompting"
    /\ decision_stage = "undecided"
    /\ cascade_state = "idle"
    /\ ~measurement_bound
    /\ measurement_bound' = TRUE
    /\ UNCHANGED <<turn_live, turn_phase, decision_stage, cascade_state>>

GuardOk ==
    /\ turn_live
    /\ turn_phase = "prompting"
    /\ measurement_bound
    /\ decision_stage = "undecided"
    /\ decision_stage' = "guard_ok"
    /\ UNCHANGED <<turn_live, turn_phase, cascade_state, measurement_bound>>

\* Runtime may surface policy selection from undecided or from guard_ok, but
\* the measurement is already bound by the time the policy is committed.
SelectToolPolicy ==
    /\ turn_live
    /\ turn_phase = "prompting"
    /\ cascade_state = "idle"
    /\ measurement_bound
    /\ decision_stage \in {"undecided", "guard_ok"}
    /\ decision_stage' = "tool_policy_selected"
    /\ cascade_state' = "selecting"
    /\ UNCHANGED <<turn_live, turn_phase, measurement_bound>>

\* Entering the provider attempt preserves the decision stage but advances the
\* cascade lane into the live trying state.
CascadeTrying ==
    /\ turn_live
    /\ turn_phase = "prompting"
    /\ decision_stage = "tool_policy_selected"
    /\ cascade_state = "selecting"
    /\ turn_phase' = "executing"
    /\ cascade_state' = "trying"
    /\ UNCHANGED <<turn_live, decision_stage, measurement_bound>>

\* Guards short-circuit during pre_tool_use while the live attempt is trying.
GateRejected ==
    /\ turn_live
    /\ turn_phase = "executing"
    /\ decision_stage = "tool_policy_selected"
    /\ cascade_state = "trying"
    /\ turn_phase' = "finalizing"
    /\ decision_stage' = "gate_rejected"
    /\ UNCHANGED <<turn_live, cascade_state, measurement_bound>>

\* Overflow retry resets the decision lane to a fresh post-guard posture.
RetryAfterCompaction ==
    /\ turn_live
    /\ turn_phase = "compacting"
    /\ decision_stage = "tool_policy_selected"
    /\ decision_stage' = "guard_ok"
    /\ cascade_state' = "idle"
    /\ turn_phase' = "prompting"
    /\ UNCHANGED <<turn_live, measurement_bound>>

FinishTurn ==
    /\ turn_live
    /\ turn_phase \in (TurnPhaseSet \ {"idle"})
    /\ turn_live' = FALSE
    /\ turn_phase' = "idle"
    /\ decision_stage' = "undecided"
    /\ cascade_state' = "idle"
    /\ measurement_bound' = FALSE

Next ==
    \/ StartTurn
    \/ BindMeasurement
    \/ GuardOk
    \/ SelectToolPolicy
    \/ CascadeTrying
    \/ GateRejected
    \/ RetryAfterCompaction
    \/ FinishTurn

Spec ==
    Init /\ [][Next]_vars /\ WF_vars(FinishTurn)

NoLiveTurnClearsDecision ==
    ~turn_live =>
        /\ turn_phase = "idle"
        /\ decision_stage = "undecided"
        /\ cascade_state = "idle"
        /\ ~measurement_bound

IdleRequiresUndecided ==
    turn_phase = "idle" => decision_stage = "undecided"

GuardOkRequiresMeasurement ==
    decision_stage = "guard_ok" =>
        /\ turn_live
        /\ turn_phase = "prompting"
        /\ measurement_bound
        /\ cascade_state = "idle"

DecisionBoundaryRequiresMeasurement ==
    decision_stage \in {"guard_ok", "tool_policy_selected", "gate_rejected"} =>
        /\ turn_live
        /\ measurement_bound

GateRejectedRequiresFinalizing ==
    decision_stage = "gate_rejected" =>
        /\ turn_live
        /\ turn_phase = "finalizing"

NonIdleCascadeRequiresDecisionBoundary ==
    cascade_state \in {"selecting", "trying", "done", "exhausted"} =>
        /\ turn_live
        /\ decision_stage \in {"tool_policy_selected", "gate_rejected"}

SelectingRequiresPrompting ==
    cascade_state = "selecting" =>
        /\ turn_live
        /\ turn_phase = "prompting"

Safety ==
    /\ TypeOK
    /\ NoLiveTurnClearsDecision
    /\ IdleRequiresUndecided
    /\ GuardOkRequiresMeasurement
    /\ DecisionBoundaryRequiresMeasurement
    /\ GateRejectedRequiresFinalizing
    /\ NonIdleCascadeRequiresDecisionBoundary
    /\ SelectingRequiresPrompting

DecisionEventuallyClears ==
    decision_stage /= "undecided" ~> decision_stage = "undecided"

Liveness ==
    DecisionEventuallyClears

BugSelectWithoutMeasurement ==
    /\ turn_live
    /\ turn_phase = "prompting"
    /\ cascade_state = "idle"
    /\ decision_stage = "undecided"
    /\ ~measurement_bound
    /\ decision_stage' = "tool_policy_selected"
    /\ cascade_state' = "selecting"
    /\ UNCHANGED <<turn_live, turn_phase, measurement_bound>>

SpecBuggy == Init /\ [][Next \/ BugSelectWithoutMeasurement]_vars /\ WF_vars(FinishTurn)

====
