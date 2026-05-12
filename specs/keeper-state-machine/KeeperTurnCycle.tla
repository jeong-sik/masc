---- MODULE KeeperTurnCycle ----
(***************************************************************************)
(* KeeperTurnCycle — runtime-aligned turn observation contract.            *)
(*                                                                         *)
(* This spec models the live per-turn observation that the OCaml runtime   *)
(* stores in [Keeper_registry.current_turn_observation]. It is not the old *)
(* "tool_call/side_effect/done" linear storyboard; the current runtime is  *)
(* a 3-axis machine:                                                        *)
(*   - turn_phase      : prompting | routing | executing | compacting |    *)
(*                       finalizing | exhausted                            *)
(*   - decision_stage  : undecided | guard_ok | gate_rejected |            *)
(*                       tool_policy_selected                              *)
(*   - cascade_state   : idle | selecting | trying | done | exhausted      *)
(*                                                                         *)
(* Turn idle is represented by [turn_live = FALSE] plus cleared substate.  *)
(* The authoritative write points live in:                                  *)
(*   - keeper_registry.ml                                                  *)
(*   - keeper_agent_run.ml                                                 *)
(*   - keeper_unified_turn.ml                                              *)
(*   - keeper_guards.ml                                                    *)
(***************************************************************************)
(*                                                                         *)
(* OCaml <-> TLA+ mapping (see #8642 family):                              *)
(*                                                                         *)
(*   spec variable        | OCaml field / type                       | source *)
(*   ---------------------+------------------------------------------+--------*)
(*   turn_live            | current_turn_observation = Some _        | record on keeper_runtime *)
(*   turn_phase           | type turn_phase                          | lib/keeper/keeper_registry.ml — type turn_phase *)
(*   decision_stage       | type decision_stage                      | lib/keeper/keeper_registry.ml — type decision_stage *)
(*   cascade_state        | type cascade_state                       | lib/keeper/keeper_registry.ml — type cascade_state *)
(*   measurement_bound    | observation.measurement_bound : bool     | record field *)
(*   selected_model_bound | observation.selected_model = Some _      | record field *)
(*                                                                         *)
(* Authoritative write points -- 4 OCaml files cooperate.                  *)
(* Line numbers verified against main as of 2026-04-28. Function names are *)
(* stable identifiers; lines drift across edits and are informational only.*)
(*                                                                         *)
(*   lib/keeper/keeper_registry.ml -- raw setters (single source of truth) *)
(*     line 493   mark_turn_started                                        *)
(*     line 515   mark_turn_measurement                                    *)
(*     line 535   set_turn_decision_stage                                  *)
(*     line 544   set_turn_cascade_state                                   *)
(*     line 566   set_turn_selected_model                                  *)
(*     line 575   prepare_turn_retry_after_compaction                      *)
(*     line 590   mark_turn_gate_rejected_by_name                          *)
(*     line 614   mark_turn_finished                                       *)
(*                                                                         *)
(*   lib/keeper/keeper_unified_turn.ml -- top-level turn orchestration     *)
(*     line 1559  mark_turn_started        (StartTurn)                     *)
(*     line 1576  set_turn_decision_stage  (GuardOk -- when measurement bound) *)
(*     line 1616  mark_turn_finished       (FinishTurn -- in finally)      *)
(*     retry_loop sets CascadeDone/Exhausted directly; CascadeTrying is    *)
(*     now materialised inside the disclosure hook below (atomic group     *)
(*     with SelectToolPolicy) so the [idle -> trying] jump is avoided.     *)
(*     line 1813  set_turn_selected_model  (CascadeDone)                   *)
(*     line 2052  prepare_turn_retry_after_compaction  (RetryAfterCompaction) *)
(*                                                                         *)
(*   lib/keeper/keeper_run_tools.ml -- BeforeTurnParams disclosure hook    *)
(*     set_turn_decision_stage = Decision_tool_policy_selected             *)
(*     set_turn_cascade_state  = Cascade_selecting                         *)
(*     set_turn_cascade_state  = Cascade_trying                            *)
(*       (atomic group materialising SelectToolPolicy + CascadeTrying;     *)
(*        keeping the two transitions adjacent at the only site that       *)
(*        asserts decision_stage = tool_policy_selected satisfies          *)
(*        SelectingRequiresToolPolicy and avoids the idle-to-trying jump   *)
(*        that PR #14153's runtime guard rejects.)                         *)
(*                                                                         *)
(*   lib/keeper/keeper_guards.ml -- pre_tool_use override / approval gate  *)
(*     line 143   mark_turn_gate_rejected_by_name  (GateRejected)          *)
(*       (called from inside [emit_gate_event]; #11634 added the OCaml-side*)
(*        navigation block citing this spec)                               *)
(*                                                                         *)
(* Composite contract (why this spec exists alongside the 1-axis specs):   *)
(*                                                                         *)
(*   - KeeperDecisionPipeline   covers decision_stage in isolation.        *)
(*   - KeeperCascadeLifecycle   covers cascade_state in isolation.         *)
(*   - KeeperConditionsGovernPhase covers handoff signal in isolation.    *)
(*                                                                         *)
(*   This spec is the COMPOSITE -- the 3-axis invariants below             *)
(*     (SelectingRequiresToolPolicy, ExecutingRequiresTrying,              *)
(*      CompactingRequiresTrying, TerminalCascadeRequiresFinalizing)       *)
(*   are CROSS-AXIS and cannot be expressed in any single-axis sibling.    *)
(*   That is the load-bearing reason this spec is not redundant.           *)
(*                                                                         *)
(* Adding new constructors:                                                *)
(*   - new turn_phase    -> update TurnPhaseSet + every action's phase guard *)
(*   - new decision_stage-> update DecisionSet + per-axis sibling spec     *)
(*   - new cascade_state -> update CascadeSet + cross-axis invariants here *)
(*                                                                         *)
(* Out-of-scope (intentionally not modelled):                              *)
(*   - selected_model identity (just a boolean here)                       *)
(*   - cascade attempt graph below the keeper-facing projection            *)
(*     (Llm_provider / cascade_runtime cycle)                              *)
(*   - the full keeper lifecycle FSM in keeper_state_machine.ml            *)
(*     (Offline / Running / Crashed / etc. -- orthogonal axis)             *)
(*   - `routing` and `exhausted` ACTION-LEVEL transitions (B-2 gap).       *)
(*     TurnPhaseSet on line ~127 includes both members since iter 28       *)
(*     (#14793) for typed exhaustiveness — but the spec's Next disjunction *)
(*     defines no actions transitioning *into* either phase.  Reachable    *)
(*     state graph stays at 10 distinct states (depth 6); routing/         *)
(*     exhausted are vacuously satisfied by cross-axis invariants.         *)
(*                                                                         *)
(*     OCaml `keeper_registry.ml`'s `module Turn_phase_transition` (GADT-encoded turn_phase transitions) declares the cross-state transitions      *)
(*     (Prompting_to_routing, Routing_to_prompting/_routing/_executing/    *)
(*     _exhausted, Executing_to_routing, Prompting_to_exhausted) — the     *)
(*     keeper-projection view of the per-attempt cascade FSM.              *)
(*                                                                         *)
(*     Attempt-internal modeling is THE RESPONSIBILITY OF                  *)
(*     KeeperCascadeAttemptFSM.tla (KCAF), which models 6 attempt phases   *)
(*     + 3 BugActions independently of the turn-level projection.  See:   *)
(*       - docs/tla-audit/ktc-b2-routing-action-modeling-2026-05-12.md     *)
(*         (R-B-2.a/b/c RFC candidates and TLC state-space estimate)       *)
(*       - docs/tla-audit/kcaf-d1-attempt-fsm-coverage-2026-05-12.md       *)
(*         (KCAF coverage analysis)                                        *)
(*                                                                         *)
(*     Why this projection is sound: the GADT type signatures on the      *)
(*     OCaml side enforce compile-time exhaustiveness — drift in the      *)
(*     transition graph cannot land without modifying the typed GADT.     *)
(*     KCAF carries the per-attempt safety properties (SlotReleasedOnTermi-*)
(*     nal, HardQuotaTerminalImmediate, TryNextProgresses), so the        *)
(*     keeper-projection in KTC can remain a coverage-narrow type-only    *)
(*     surface until R-B-2.{a,b} lands a deliberate action set.            *)

EXTENDS TLC

VARIABLES
    turn_live,            \* current_turn_observation = Some _
    turn_phase,           \* Keeper_registry.turn_phase
    decision_stage,       \* Keeper_registry.decision_stage
    cascade_state,        \* Keeper_registry.cascade_state
    measurement_bound,    \* mark_turn_measurement already consumed
    selected_model_bound  \* selected_model = Some _

vars ==
    << turn_live, turn_phase, decision_stage, cascade_state,
       measurement_bound, selected_model_bound >>

\* TurnPhaseSet: phase membership type.
\*
\* R-B-1.a (iter 28, 2026-05-12): `routing` and `exhausted` added to close
\* the spec drift identified by `audit-tla-annotation-drift.sh`.  OCaml has
\* carried these since PR #14395 (Turn_routing active + Turn_exhausted
\* terminal).  This commit extends the type widening only; per-action
\* transition modeling (e.g. RoutingStart, RoutingExhausted, retry pumps
\* through routing) is intentionally deferred — see B-2 follow-up audit
\* (`docs/tla-audit/ktc-b1-turn-phase-spec-gap-2026-05-12.md`).
\*
\* The wider set keeps TypeOK total (every OCaml turn_phase is now
\* spec-typable) without altering the reachable state graph: Init pins
\* `turn_phase = "idle"` and no existing action transitions into routing
\* or exhausted, so TLC clean+buggy state counts are unchanged.  The
\* cross-axis invariants (SelectingRequiresToolPolicy etc.) are
\* conditional on specific phase membership and are not affected.
TurnPhaseSet == {"idle", "prompting", "routing", "executing",
                 "compacting", "finalizing", "exhausted"}
DecisionSet  == {"undecided", "guard_ok", "gate_rejected", "tool_policy_selected"}
CascadeSet   == {"idle", "selecting", "trying", "done", "exhausted"}
ActionSet    == {
    "StartTurn",
    "BindMeasurement",
    "GuardOk",
    "SelectToolPolicy",
    "GateRejected",
    "CascadeTrying",
    "CascadeDone",
    "CascadeExhausted",
    "EnterCompacting",
    "RetryAfterCompaction",
    "FinishTurn"
}
InvariantSet == {
    "NoLiveTurnClearsState",
    "IdleRequiresNotLive",
    "GateRejectedRequiresFinalizing",
    "SelectingRequiresToolPolicy",
    "ExecutingRequiresTrying",
    "CompactingRequiresTrying",
    "TerminalCascadeRequiresFinalizing"
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

\* ──────────────────────────────────────────────────────────────────────
\* Live turn installation
\* keeper_unified_turn.ml: mark_turn_started
\* ──────────────────────────────────────────────────────────────────────
StartTurn ==
    /\ ~turn_live
    /\ turn_live' = TRUE
    /\ turn_phase' = "prompting"
    /\ decision_stage' = "undecided"
    /\ cascade_state' = "idle"
    /\ measurement_bound' = FALSE
    /\ selected_model_bound' = FALSE

\* mark_turn_measurement
BindMeasurement ==
    /\ turn_live
    /\ turn_phase = "prompting"
    /\ decision_stage = "undecided"
    /\ cascade_state = "idle"
    /\ ~measurement_bound
    /\ measurement_bound' = TRUE
    /\ UNCHANGED <<turn_live, turn_phase, decision_stage,
                    cascade_state, selected_model_bound>>

\* keeper_unified_turn.ml elevates guard_ok when a measurement is present.
GuardOk ==
    /\ turn_live
    /\ turn_phase = "prompting"
    /\ measurement_bound
    /\ decision_stage = "undecided"
    /\ decision_stage' = "guard_ok"
    /\ UNCHANGED <<turn_live, turn_phase, cascade_state,
                    measurement_bound, selected_model_bound>>

\* keeper_agent_run.ml: tool disclosure completes, selected policy becomes active.
\* Runtime may surface the decision stage as undecided or guard_ok here, but
\* the measurement must already be bound before policy selection commits.
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

\* keeper_guards.ml: override/approval_required short-circuits during the live
\* pre_tool_use attempt. The runtime preserves the current trying edge and only
\* moves the turn into finalizing.
GateRejected ==
    /\ turn_live
    /\ turn_phase = "executing"
    /\ decision_stage = "tool_policy_selected"
    /\ cascade_state = "trying"
    /\ turn_phase' = "finalizing"
    /\ decision_stage' = "gate_rejected"
    /\ UNCHANGED <<turn_live, cascade_state, measurement_bound,
                    selected_model_bound>>

\* keeper_unified_turn.ml: retry_loop sets Cascade_trying before OAS run.
CascadeTrying ==
    /\ turn_live
    /\ turn_phase = "prompting"
    /\ decision_stage = "tool_policy_selected"
    /\ cascade_state = "selecting"
    /\ turn_phase' = "executing"
    /\ cascade_state' = "trying"
    /\ UNCHANGED <<turn_live, decision_stage, measurement_bound,
                    selected_model_bound>>

\* Successful cascade attempt chooses a model and enters finalizing.
CascadeDone ==
    /\ turn_live
    /\ turn_phase = "executing"
    /\ cascade_state = "trying"
    /\ turn_phase' = "finalizing"
    /\ cascade_state' = "done"
    /\ selected_model_bound' = TRUE
    /\ UNCHANGED <<turn_live, decision_stage, measurement_bound>>

\* Exhausted cascade also terminates the turn, without binding a model.
CascadeExhausted ==
    /\ turn_live
    /\ turn_phase = "executing"
    /\ cascade_state = "trying"
    /\ turn_phase' = "finalizing"
    /\ cascade_state' = "exhausted"
    /\ UNCHANGED <<turn_live, decision_stage, measurement_bound,
                    selected_model_bound>>

\* Overflow recovery enters explicit compaction while preserving the trying edge.
EnterCompacting ==
    /\ turn_live
    /\ turn_phase = "executing"
    /\ cascade_state = "trying"
    /\ turn_phase' = "compacting"
    /\ UNCHANGED <<turn_live, decision_stage, cascade_state,
                    measurement_bound, selected_model_bound>>

\* keeper_unified_turn.ml: prepare_turn_retry_after_compaction
\* Re-enters prompting with the measurement still bound, but clears the old
\* cascade attempt and selected model before the next retry.
RetryAfterCompaction ==
    /\ turn_live
    /\ turn_phase = "compacting"
    /\ cascade_state = "trying"
    /\ turn_phase' = "prompting"
    /\ decision_stage' = "guard_ok"
    /\ cascade_state' = "idle"
    /\ selected_model_bound' = FALSE
    /\ UNCHANGED <<turn_live, measurement_bound>>

\* keeper_unified_turn.ml finally block: mark_turn_finished clears live state.
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
    \/ GateRejected
    \/ CascadeTrying
    \/ CascadeDone
    \/ CascadeExhausted
    \/ EnterCompacting
    \/ RetryAfterCompaction
    \/ FinishTurn

\* ── Bug Model: Selecting Without Tool Policy ───────────────
\* Models a regression where cascade_state jumps to "selecting"
\* without decision_stage being "tool_policy_selected".
\* SHOULD violate SelectingRequiresToolPolicy.

BugSelectingWithoutToolPolicy ==
    /\ turn_live
    /\ turn_phase = "prompting"
    /\ decision_stage = "guard_ok"  \* BUG: not tool_policy_selected
    /\ cascade_state' = "selecting"
    /\ UNCHANGED <<turn_live, turn_phase, decision_stage,
                    measurement_bound, selected_model_bound>>

NextBuggy ==
    \/ Next
    \/ BugSelectingWithoutToolPolicy

SpecBuggy == Init /\ [][NextBuggy]_vars /\ WF_vars(FinishTurn)

Spec ==
    Init /\ [][Next]_vars /\ WF_vars(FinishTurn)

\* ──────────────────────────────────────────────────────────────────────
\* Invariants
\* ──────────────────────────────────────────────────────────────────────

NoLiveTurnClearsState ==
    ~turn_live =>
        /\ turn_phase = "idle"
        /\ decision_stage = "undecided"
        /\ cascade_state = "idle"
        /\ ~measurement_bound
        /\ ~selected_model_bound

IdleRequiresNotLive ==
    turn_phase = "idle" => ~turn_live

GateRejectedRequiresFinalizing ==
    decision_stage = "gate_rejected" => turn_phase = "finalizing"

SelectingRequiresToolPolicy ==
    cascade_state = "selecting" =>
        /\ turn_live
        /\ turn_phase = "prompting"
        /\ decision_stage = "tool_policy_selected"

ExecutingRequiresTrying ==
    turn_phase = "executing" =>
        /\ turn_live
        /\ cascade_state = "trying"
        /\ decision_stage = "tool_policy_selected"

CompactingRequiresTrying ==
    turn_phase = "compacting" =>
        /\ turn_live
        /\ cascade_state = "trying"
        /\ decision_stage = "tool_policy_selected"

TerminalCascadeRequiresFinalizing ==
    cascade_state \in {"done", "exhausted"} =>
        /\ turn_live
        /\ turn_phase = "finalizing"
        /\ decision_stage = "tool_policy_selected"

Safety ==
    /\ TypeOK
    /\ NoLiveTurnClearsState
    /\ IdleRequiresNotLive
    /\ GateRejectedRequiresFinalizing
    /\ SelectingRequiresToolPolicy
    /\ ExecutingRequiresTrying
    /\ CompactingRequiresTrying
    /\ TerminalCascadeRequiresFinalizing

(* Wrapper for buggy cfg — must be defined AFTER the invariant it references. *)
SelectingRequiresToolPolicyMustHold == SelectingRequiresToolPolicy

LiveTurnEventuallyClears ==
    turn_live ~> ~turn_live

Liveness ==
    LiveTurnEventuallyClears

====
