(** Keeper_registry_types — pure type definitions extracted from
    Keeper_registry (3041 LoC godfile).

    Holds the [failure_reason] cluster + pure converters. State-mutating
    operations remain in Keeper_registry. Re-included by Keeper_registry
    so existing 126 callers continue to use [Keeper_registry.failure_reason]
    unchanged. *)

open Keeper_types

(** Structured failure reason for crash cohort detection. *)
type ambiguous_partial_commit_kind =
  | Post_commit_timeout
  | Post_commit_failure

type ambiguous_partial_commit = {
  kind : ambiguous_partial_commit_kind;
  detail : string;
}

(** Phase B PR-6 (2026-04-28): the stale watchdog's three distinct kill
    causes used to collapse into a single [Stale_turn_timeout of float]
    variant.  Operators / dashboards could not tell whether a kill was an
    idle stall (turn never started), an active turn hang (turn running
    too long), or a no-op failure loop (turn fired but produced no tool
    calls) — three different root causes that need different operator
    actions.  Splitting the payload preserves the [Stale_turn_timeout]
    cohort key so existing dashboards keep working, while exposing the
    typed sub-class to anything that wants to discriminate. *)
type stale_kill_class =
  | Idle_turn of { stall_seconds : float }
      (** [last_turn_ts] older than the idle threshold while the keeper
          phase is [Running] but no [current_turn_observation] is
          recorded. *)
  | In_turn_hung of {
      active_seconds : float;
      timeout_threshold : float;
    }
      (** A turn started ([current_turn_observation = Some]) and ran past
          [timeout_threshold] seconds. *)
  | Noop_failure_loop of { noop_count : int }
      (** Turns kept firing but produced no tool calls; the keepalive's
          [consecutive_noop_count] reached the watchdog threshold. *)

val stale_kill_class_to_string : stale_kill_class -> string
(** Operator-facing label.  Used in [failure_reason_to_string] for the
    [Stale_turn_timeout] arm and exposed for dashboards / metrics that
    want to attribute kills by class. *)

type failure_reason =
  | Heartbeat_consecutive_failures of int
  | Turn_consecutive_failures of int
  | Stale_turn_timeout of stale_kill_class
  | Stale_termination_storm of { count : int }
      (** #10765 Phase 2: latched when [record_stale_termination] returns a
          window count >= [escalation_threshold]. The supervisor's
          [`Crashed] branch checks this variant and skips [to_restart],
          persisting [meta.paused = true] instead so an operator must
          investigate the underlying cascade/provider/fd issue before
          resuming the keeper. *)
  | Stale_fleet_batch of { distinct_count : int }
      (** Latched when the stale watchdog observes several distinct keepers
          terminating inside the fleet batch window. This is a systemic
          cascade/provider/runtime signal, so the supervisor pauses affected
          keepers with auto-resume backoff instead of restarting each keeper
          independently into the same failure mode. *)
  | Oas_timeout_budget_loop of { count : int }
      (** Latched when the same keeper exhausts the OAS turn budget on
          consecutive cycles. This is a provider/cascade/runtime throughput
          failure, so the supervisor pauses instead of restarting into the
          same slow model and burning another multi-minute budget. *)
  | Provider_runtime_error of { code : string; detail : string }
      (** Latched from the keeper turn terminal reason when the provider,
          adapter, or cascade fails before useful keeper progress. A later
          idle watchdog should preserve this root cause instead of recasting
          the keeper as generically stale. *)
  | Tool_required_unsatisfied of { code : string; detail : string }
      (** Latched when an actionable required-tool turn returned no useful
          keeper tool progress. *)
  | Ambiguous_partial_commit of ambiguous_partial_commit
  | Fiber_unresolved
  | Exception of string

val ambiguous_partial_commit_kind_to_string :
  ambiguous_partial_commit_kind -> string

val failure_reason_to_string : failure_reason -> string

(** #10584: cohort key for grouping failures by variant (ignores
    parameters). [None] returns ["unknown"]. New variants added to
    [failure_reason] force a same-PR update of this function via
    OCaml's exhaustive-match check — Option B mitigation for the
    recurring P0 pattern (#10490, #10574). *)
val failure_reason_cohort_key : failure_reason option -> string

val stale_watchdog_failure_reason :
  prior:failure_reason option -> kill_class:stale_kill_class -> failure_reason option
(** Preserve authoritative terminal failure reasons when the stale watchdog
    fires after a failed turn, but do not carry stale-watchdog cohort labels
    across fresh watchdog kills. Storm/fleet labels are relatched only by the
    current threshold or batch detector. *)

(** Pure control-flow signal for immediate fiber termination (RFC-0002).
    Carries no state — failure reason must be pre-stored via
    [set_failure_reason] before raising. *)
exception Keeper_fiber_crash
type turn_phase =
  | Turn_idle [@tla.idle]
  | Turn_prompting [@tla.active]
  | Turn_routing [@tla.active]
  | Turn_executing [@tla.active]
  | Turn_compacting [@tla.active]
  | Turn_finalizing [@tla.active]
  | Turn_exhausted [@tla.terminal]
[@@deriving tla]

(** {1 Turn phase GADT infrastructure (Cycle 21 / Tier B5)} *)

type turn_idle
type turn_prompting
type turn_routing
type turn_executing
type turn_compacting
type turn_finalizing
type turn_exhausted

type 'a turn_phase_witness =
  | Turn_idle : turn_idle turn_phase_witness
  | Turn_prompting : turn_prompting turn_phase_witness
  | Turn_routing : turn_routing turn_phase_witness
  | Turn_executing : turn_executing turn_phase_witness
  | Turn_compacting : turn_compacting turn_phase_witness
  | Turn_finalizing : turn_finalizing turn_phase_witness
  | Turn_exhausted : turn_exhausted turn_phase_witness

type packed_turn_phase = Packed : 'a turn_phase_witness -> packed_turn_phase

val witness_to_turn_phase : packed_turn_phase -> turn_phase
val turn_phase_to_witness : turn_phase -> packed_turn_phase

(** Diagnostic label using the constructor name (e.g. ["Turn_routing"]).
    Used by the [Turn_phase_transition_violation] [Printexc] printer to
    render the rejected pair.  Distinct from
    [Keeper_composite_observer.turn_phase_to_string] which emits a
    snake_case form for dashboards. *)
val packed_turn_phase_label : packed_turn_phase -> string

(** RFC-0072 Phase 4: GADT-encoded turn_phase transitions, aligned with
    [Cascade_transition].  Enumerates the 23 valid cross-state transitions
    of the 7-variant [turn_phase] FSM.  The 19 forbidden pairs have no
    constructor and are therefore type-unrepresentable.  Idempotent
    self-loops are not represented (mutator-boundary no-ops). *)
module Turn_phase_transition : sig
  type ('from, 'to_) t =
    | Idle_to_prompting : (turn_idle, turn_prompting) t
    | Prompting_to_routing : (turn_prompting, turn_routing) t
    | Prompting_to_executing : (turn_prompting, turn_executing) t
    | Prompting_to_finalizing : (turn_prompting, turn_finalizing) t
    | Prompting_to_exhausted : (turn_prompting, turn_exhausted) t
    | Routing_to_prompting : (turn_routing, turn_prompting) t
    | Routing_to_executing : (turn_routing, turn_executing) t
    | Routing_to_exhausted : (turn_routing, turn_exhausted) t
    | Executing_to_prompting : (turn_executing, turn_prompting) t
    | Executing_to_routing : (turn_executing, turn_routing) t
    | Executing_to_compacting : (turn_executing, turn_compacting) t
    | Executing_to_finalizing : (turn_executing, turn_finalizing) t
    | Executing_to_exhausted : (turn_executing, turn_exhausted) t
    | Compacting_to_prompting : (turn_compacting, turn_prompting) t
    | Compacting_to_finalizing : (turn_compacting, turn_finalizing) t
    | Compacting_to_exhausted : (turn_compacting, turn_exhausted) t
    | Finalizing_to_prompting : (turn_finalizing, turn_prompting) t
    | Finalizing_to_routing : (turn_finalizing, turn_routing) t
    | Finalizing_to_executing : (turn_finalizing, turn_executing) t
    | Finalizing_to_exhausted : (turn_finalizing, turn_exhausted) t
    | Exhausted_to_prompting : (turn_exhausted, turn_prompting) t
    | Exhausted_to_routing : (turn_exhausted, turn_routing) t
    | Exhausted_to_executing : (turn_exhausted, turn_executing) t

  type packed = Packed_transition : ('a, 'b) t -> packed

  val to_tag : ('from, 'to_) t -> string
end

(** RFC-0072 Phase 4: typed error for turn_phase transition spec violations. *)
type turn_phase_transition_spec_violation =
  | Idle_to_routing
  | Idle_to_executing
  | Idle_to_compacting
  | Idle_to_finalizing
  | Idle_to_exhausted
  | Prompting_to_idle
  | Prompting_to_compacting
  | Routing_to_idle
  | Routing_to_compacting
  | Routing_to_finalizing
  | Executing_to_idle
  | Compacting_to_idle
  | Compacting_to_routing
  | Compacting_to_executing
  | Finalizing_to_idle
  | Finalizing_to_compacting
  | Exhausted_to_idle
  | Exhausted_to_compacting
  | Exhausted_to_finalizing

val turn_phase_transition_spec_violation_to_tag
  :  turn_phase_transition_spec_violation
  -> string

(** RFC-0072 Phase 5: raised by [validate_turn_phase_transition] and
    [set_turn_phase] on a forbidden turn_phase transition, carrying the
    typed [turn_phase_transition_spec_violation] payload (replaces the
    prior string-formatted [Invalid_argument]).  [where] is a diagnostic
    label naming the raising function.  A [Printexc] printer is registered
    so [Printexc.to_string] reproduces the original message text. *)
exception
  Turn_phase_transition_violation of
    { where : string
    ; from : packed_turn_phase
    ; to_ : packed_turn_phase
    ; violation : turn_phase_transition_spec_violation
    }

(** RFC-0072 Phase 4: resolve a (from, target) packed pair to one of three
    outcomes.  Mirrors [resolve_cascade_transition]. *)
type turn_phase_resolve_outcome =
  | Resolved_turn_transition of Turn_phase_transition.packed
  | Resolved_turn_idempotent
  | Resolved_turn_violation of turn_phase_transition_spec_violation

val resolve_turn_phase_transition
  :  from:packed_turn_phase
  -> target:packed_turn_phase
  -> turn_phase_resolve_outcome

(** Raises [Turn_phase_transition_violation] with the typed payload.
    Previously a private helper inside Keeper_registry; exposed via the
    intra-library split (2026-05-16) because [validate_turn_phase_transition]
    in Keeper_registry calls it after moving the exception here. *)
val raise_turn_phase_transition_violation
  :  where:string
  -> from:packed_turn_phase
  -> to_:packed_turn_phase
  -> violation:turn_phase_transition_spec_violation
  -> 'a
type decision_stage =
  | Decision_undecided [@tla.idle]
  | Decision_guard_ok [@tla.active]
  | Decision_gate_rejected [@tla.terminal]
  | Decision_tool_policy_selected [@tla.active]
[@@deriving tla]

(** {1 Decision stage GADT infrastructure (Cycle 21 / Tier B5)} *)

type decision_undecided
type decision_guard_ok
type decision_gate_rejected
type decision_tool_policy_selected

type 'a decision_stage_witness =
  | Decision_undecided : decision_undecided decision_stage_witness
  | Decision_guard_ok : decision_guard_ok decision_stage_witness
  | Decision_gate_rejected : decision_gate_rejected decision_stage_witness
  | Decision_tool_policy_selected : decision_tool_policy_selected decision_stage_witness

type packed_decision_stage = Packed : 'a decision_stage_witness -> packed_decision_stage

val witness_to_stage : 'a decision_stage_witness -> decision_stage
val stage_to_witness : decision_stage -> packed_decision_stage

(** Decision stages valid as ADVANCE targets within a turn.  Excludes
    [Decision_undecided] (the initial state set only by [mark_turn_started]
    / [mark_sdk_turn_started]).  The 3 spec-forbidden [<active>_to_undecided]
    transitions are unrepresentable through this type, replacing the prior
    runtime [invalid_arg] inside [set_turn_decision_stage]. *)
type decision_stage_active =
  | Decision_active_guard_ok
  | Decision_active_gate_rejected
  | Decision_active_tool_policy_selected

val decision_stage_active_to_packed
  :  decision_stage_active
  -> packed_decision_stage

(** Diagnostic label using the constructor name (e.g.
    ["Decision_guard_ok"]).  Used by [validate_cascade_transition] /
    [validate_turn_phase_transition] for [Invalid_argument] messages. *)
val packed_decision_stage_label : packed_decision_stage -> string

(** Living-matrix documentation of the decision-stage transition relation.
    Forbidden [<active>_to_undecided] pairs are unrepresentable through the
    [decision_stage_active] target type, so this validator no longer raises;
    it exists as a compile-time fixture that enumerates every admitted pair.
    Adding a new variant to either side will trigger Warning 8 here, forcing
    the maintainer to classify the new pair. *)
val validate_decision_transition
  :  from:decision_stage
  -> to_:decision_stage_active
  -> unit

module Decision_transition : sig
  type ('from, 'to_) t =
    | Undecided_to_guard_ok : (decision_undecided, decision_guard_ok) t
    | Undecided_to_gate_rejected : (decision_undecided, decision_gate_rejected) t
    | Undecided_to_tool_policy_selected : (decision_undecided, decision_tool_policy_selected) t
    | Guard_ok_to_gate_rejected : (decision_guard_ok, decision_gate_rejected) t
    | Guard_ok_to_tool_policy_selected : (decision_guard_ok, decision_tool_policy_selected) t
    | Gate_rejected_to_guard_ok : (decision_gate_rejected, decision_guard_ok) t
    | Gate_rejected_to_tool_policy_selected : (decision_gate_rejected, decision_tool_policy_selected) t
    | Tool_policy_selected_to_guard_ok : (decision_tool_policy_selected, decision_guard_ok) t
    | Tool_policy_selected_to_gate_rejected : (decision_tool_policy_selected, decision_gate_rejected) t

  val to_tag : ('from, 'to_) t -> string
end

