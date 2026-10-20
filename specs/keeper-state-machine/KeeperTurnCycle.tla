---- MODULE KeeperTurnCycle ----
(***************************************************************************)
(* KeeperTurnCycle — runtime-aligned turn observation contract.            *)
(*                                                                         *)
(* This spec models the live per-turn observation that the OCaml runtime   *)
(* stores in [Keeper_registry.current_turn_observation]. It is not the old *)
(* "tool_call/side_effect/done" linear storyboard; the current runtime is  *)
(* a 2-axis machine:                                                        *)
(*   - turn_phase      : prompting | routing | executing |               *)
(*                       finalizing | exhausted                            *)
(*   - decision_stage  : undecided | guard_ok | tool_policy_selected       *)
(*                                                                         *)
(* Turn idle is represented by [turn_live = FALSE] plus cleared substate.  *)
(* The authoritative write points live in:                                  *)
(*   - keeper_registry.ml                                                  *)
(*   - keeper_agent_run.ml                                                 *)
(*   - keeper_unified_turn.ml                                              *)
(***************************************************************************)
(*                                                                         *)
(* OCaml <-> TLA+ mapping (see #8642 family):                              *)
(*                                                                         *)
(*   spec variable        | OCaml field / type                       | source *)
(*   ---------------------+------------------------------------------+--------*)
(*   turn_live            | current_turn_observation = Some _        | record on keeper_runtime *)
(*   turn_phase           | type turn_phase                          | lib/keeper/keeper_registry_types.ml — type turn_phase *)
(*   decision_stage       | type decision_stage                      | lib/keeper/keeper_registry_types.ml — type decision_stage *)
(*   measurement_bound    | observation.measurement_bound : bool     | record field *)
(*   selected_model_bound | observation.selected_model = Some _      | record field *)
(*                                                                         *)
(* Authoritative write points, by module and function.                     *)
(*                                                                         *)
(* The line numbers this block carried were verified on 2026-04-28.        *)
(* Checked again on 2026-09-07 they were wrong by 454 to 753 lines,        *)
(* and three of the nine symbols had left the module named here.           *)
(* Names survive an edit and offsets do not, so there are none now.        *)
(*                                                                         *)
(*   raw setters                                                           *)
(*     keeper_registry_setup.ml  mark_turn_started                         *)
(*                               mark_turn_measurement                     *)
(*                               set_turn_decision_stage                   *)
(*     keeper_registry.ml        set_turn_selected_model                   *)
(*                               mark_turn_provider_attempt_started        *)
(*                               mark_turn_finished                        *)
(*                                                                         *)
(*  who writes them                                                        *)
(*    keeper_unified_turn.ml                                               *)
(*      mark_turn_started        (StartTurn)                               *)
(*      mark_turn_measurement                                              *)
(*      set_turn_decision_stage  (GuardOk)                                 *)
(*      mark_turn_finished       (FinishTurn, in the finally)              *)
(*    keeper_unified_turn_execution.ml                                     *)
(*      set_turn_selected_model  (RuntimeDone)                             *)
(*                                                                         *)
(*   keeper_run_tools.ml wrote two of these through a BeforeTurnParams     *)
(*   disclosure hook. It writes none of them now.                          *)
(*                                                                         *)
(*   mark_turn_provider_attempt_started writes two axes in this order:     *)
(*   set_turn_decision_stage tool_policy_selected (SelectToolPolicy), then *)
(*   set_turn_phase executing (EnterExecuting). A reader can see the state *)
(*   between the two.                                                      *)
(*                                                                         *)
(* Composite contract (why this spec exists alongside the decision spec):  *)
(*                                                                         *)
(*   - KeeperDecisionPipeline   covers decision_stage up to entering       *)
(*     executing, without the attempt outcome.                             *)
(*   - This spec adds the attempt outcome (RuntimeDone, RuntimeExhausted,  *)
(*     finalizing) and selected_model_bound, and the cross-axis            *)
(*     invariants ExecutingRequiresToolPolicy and                          *)
(*     FinalizingRequiresToolPolicy.                                       *)
(*   - handoff is an orthogonal lifecycle event outside this turn model.  *)
(*                                                                         *)
(* Adding new constructors:                                                *)
(*   - new turn_phase    -> update TurnPhaseSet + every action's phase guard *)
(*   - new decision_stage-> update DecisionSet + per-axis sibling spec     *)
(*                                                                         *)
(* Out-of-scope (intentionally not modelled):                              *)
(*   - selected_model identity (just a boolean here)                       *)
(*   - runtime attempt graph below the keeper-facing projection            *)
(*     (Llm_provider / runtime_runtime cycle)                              *)
(*   - the full keeper lifecycle FSM in keeper_state_machine.ml            *)
(*     (Offline / Running / Crashed / etc. -- orthogonal axis)             *)
(*   - `routing` and `exhausted` ACTION-LEVEL transitions (B-2 gap).       *)
(*     TurnPhaseSet on line ~127 includes both members since iter 28       *)
(*     (#14793) for typed exhaustiveness — but the spec's Next disjunction *)
(*     defines no actions transitioning *into* either phase.  Reachable    *)
(*     state graph stays at 10 distinct states (depth 6); routing/         *)
(*     exhausted are vacuously satisfied by cross-axis invariants.         *)
(*                                                                         *)
(*     OCaml `keeper_registry_types.ml`'s `module Turn_phase_transition` (GADT-encoded turn_phase transitions) declares the cross-state transitions *)
(*     (Prompting_to_routing, Routing_to_prompting/_routing/_executing/    *)
(*     _exhausted, Executing_to_routing, Prompting_to_exhausted) — the     *)
(*     keeper-projection view of the per-attempt runtime FSM.              *)
(*                                                                         *)
(*     Attempt-internal modeling is THE RESPONSIBILITY OF                  *)
(*     KeeperRuntimeAttemptFSM.tla (KCAF), which models 6 attempt phases   *)
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
    measurement_bound,    \* mark_turn_measurement already consumed
    selected_model_bound  \* selected_model = Some _

vars ==
    << turn_live, turn_phase, decision_stage,
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
\* cross-axis invariants (ExecutingRequiresToolPolicy etc.) are
\* conditional on specific phase membership and are not affected.
TurnPhaseSet == {"idle", "prompting", "routing", "executing",
                 "finalizing", "exhausted"}
DecisionSet  == {"undecided", "guard_ok", "tool_policy_selected"}
ActionSet    == {
    "StartTurn",
    "BindMeasurement",
    "GuardOk",
    "SelectToolPolicy",
    "EnterExecuting",
    "RuntimeDone",
    "RuntimeExhausted",
    "FinishTurn"
}
InvariantSet == {
    "NoLiveTurnClearsState",
    "IdleRequiresNotLive",
    "ExecutingRequiresToolPolicy",
    "FinalizingRequiresToolPolicy"
}

TypeOK ==
    /\ turn_live \in BOOLEAN
    /\ turn_phase \in TurnPhaseSet
    /\ decision_stage \in DecisionSet
    /\ measurement_bound \in BOOLEAN
    /\ selected_model_bound \in BOOLEAN

Init ==
    /\ turn_live = FALSE
    /\ turn_phase = "idle"
    /\ decision_stage = "undecided"
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
    /\ measurement_bound' = FALSE
    /\ selected_model_bound' = FALSE

\* mark_turn_measurement
BindMeasurement ==
    /\ turn_live
    /\ turn_phase = "prompting"
    /\ decision_stage = "undecided"
    /\ ~measurement_bound
    /\ measurement_bound' = TRUE
    /\ UNCHANGED <<turn_live, turn_phase, decision_stage,
                    selected_model_bound>>

\* keeper_unified_turn.ml elevates guard_ok when a measurement is present.
GuardOk ==
    /\ turn_live
    /\ turn_phase = "prompting"
    /\ measurement_bound
    /\ decision_stage = "undecided"
    /\ decision_stage' = "guard_ok"
    /\ UNCHANGED <<turn_live, turn_phase,
                    measurement_bound, selected_model_bound>>

\* mark_turn_provider_attempt_started, first write: set_turn_decision_stage.
\* Runtime may surface the decision stage as undecided or guard_ok here, but
\* the measurement must already be bound before policy selection commits.
SelectToolPolicy ==
    /\ turn_live
    /\ turn_phase = "prompting"
    /\ measurement_bound
    /\ decision_stage \in {"undecided", "guard_ok"}
    /\ decision_stage' = "tool_policy_selected"
    /\ UNCHANGED <<turn_live, turn_phase, measurement_bound,
                    selected_model_bound>>

\* mark_turn_provider_attempt_started, second write: set_turn_phase executing.
\* Entering executing needs the policy already selected.
EnterExecuting ==
    /\ turn_live
    /\ turn_phase = "prompting"
    /\ decision_stage = "tool_policy_selected"
    /\ turn_phase' = "executing"
    /\ UNCHANGED <<turn_live, decision_stage, measurement_bound,
                    selected_model_bound>>

\* Successful runtime attempt chooses a model and enters finalizing.
RuntimeDone ==
    /\ turn_live
    /\ turn_phase = "executing"
    /\ turn_phase' = "finalizing"
    /\ selected_model_bound' = TRUE
    /\ UNCHANGED <<turn_live, decision_stage, measurement_bound>>

\* Exhausted runtime also terminates the turn, without binding a model.
RuntimeExhausted ==
    /\ turn_live
    /\ turn_phase = "executing"
    /\ turn_phase' = "finalizing"
    /\ UNCHANGED <<turn_live, decision_stage, measurement_bound,
                    selected_model_bound>>

\* keeper_unified_turn.ml finally block: mark_turn_finished clears live state.
FinishTurn ==
    /\ turn_live
    /\ turn_phase \in (TurnPhaseSet \ {"idle"})
    /\ turn_live' = FALSE
    /\ turn_phase' = "idle"
    /\ decision_stage' = "undecided"
    /\ measurement_bound' = FALSE
    /\ selected_model_bound' = FALSE

Next ==
    \/ StartTurn
    \/ BindMeasurement
    \/ GuardOk
    \/ SelectToolPolicy
    \/ EnterExecuting
    \/ RuntimeDone
    \/ RuntimeExhausted
    \/ FinishTurn

\* ── Bug Model: Executing Without Tool Policy ───────────────
\* Models a regression where turn_phase jumps to "executing" while
\* decision_stage is still "guard_ok" (the phase write lands before the
\* decision-stage write). SHOULD violate ExecutingRequiresToolPolicy.

BugExecutingWithoutToolPolicy ==
    /\ turn_live
    /\ turn_phase = "prompting"
    /\ decision_stage = "guard_ok"  \* BUG: not tool_policy_selected
    /\ turn_phase' = "executing"
    /\ UNCHANGED <<turn_live, decision_stage,
                    measurement_bound, selected_model_bound>>

NextBuggy ==
    \/ Next
    \/ BugExecutingWithoutToolPolicy

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
        /\ ~measurement_bound
        /\ ~selected_model_bound

IdleRequiresNotLive ==
    turn_phase = "idle" => ~turn_live

ExecutingRequiresToolPolicy ==
    turn_phase = "executing" =>
        /\ turn_live
        /\ decision_stage = "tool_policy_selected"

FinalizingRequiresToolPolicy ==
    turn_phase = "finalizing" =>
        /\ turn_live
        /\ decision_stage = "tool_policy_selected"

Safety ==
    /\ TypeOK
    /\ NoLiveTurnClearsState
    /\ IdleRequiresNotLive
    /\ ExecutingRequiresToolPolicy
    /\ FinalizingRequiresToolPolicy

(* Wrapper for buggy cfg — must be defined AFTER the invariant it references. *)
ExecutingRequiresToolPolicyMustHold == ExecutingRequiresToolPolicy

LiveTurnEventuallyClears ==
    turn_live ~> ~turn_live

Liveness ==
    LiveTurnEventuallyClears

====
