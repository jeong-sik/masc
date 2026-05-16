(** Keeper_registry_types — pure type definitions extracted from
    Keeper_registry (3041 LoC godfile).

    Holds the [failure_reason] cluster + pure converters. State-mutating
    operations remain in Keeper_registry. Re-included by Keeper_registry
    so existing 126 callers continue to use [Keeper_registry.failure_reason]
    unchanged. *)

open Keeper_types

module StringMap : Map.S with type key = string

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
  | Mid_turn_no_progress of {
      active_seconds : float;
      since_progress_seconds : float;
      progress_timeout_threshold : float;
      last_progress_kind : string option;
    }
      (** A turn is still within the outer turn cap, but no streaming/tool
          progress has been observed for [progress_timeout_threshold]
          seconds.  This separates provider no-first-token /
          inter-chunk-idle stalls from ordinary long-running turns. *)
  | Noop_failure_loop of { noop_count : int }
      (** Turns kept firing but produced no tool calls; the keepalive's
          [consecutive_noop_count] reached the watchdog threshold. *)

val progress_kind_label : string option -> string
(** Display label for optional progress-kind telemetry.  Missing means no
    streaming/tool progress label was stamped yet, rendered as ["-"]. *)

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

type cascade_state =
  | Cascade_idle [@tla.idle]
  | Cascade_selecting [@tla.active]
  | Cascade_trying [@tla.active]
  | Cascade_done [@tla.terminal]
  | Cascade_exhausted [@tla.terminal]
[@@deriving tla]

(** {1 Cascade state GADT infrastructure (Cycle 21 / Tier B5)} *)

type cascade_idle
type cascade_selecting
type cascade_trying
type cascade_done
type cascade_exhausted

type 'a cascade_state_witness =
  | Cascade_idle : cascade_idle cascade_state_witness
  | Cascade_selecting : cascade_selecting cascade_state_witness
  | Cascade_trying : cascade_trying cascade_state_witness
  | Cascade_done : cascade_done cascade_state_witness
  | Cascade_exhausted : cascade_exhausted cascade_state_witness

type packed_cascade_state =
  | Packed : 'a cascade_state_witness -> packed_cascade_state

val cascade_state_to_witness : cascade_state -> packed_cascade_state
val witness_to_cascade_state : packed_cascade_state -> cascade_state

(** Diagnostic label using the constructor name (e.g.
    ["Cascade_exhausted"]).  Used by the [Cascade_transition_violation]
    [Printexc] printer to render the rejected pair. *)
val packed_cascade_state_label : packed_cascade_state -> string

(** RFC-0072 Phase 1: GADT-encoded cascade transitions.

    Enumerates the 13 valid cross-state transitions of the 5-variant
    [cascade_state] FSM.  The 7 forbidden pairs ([Idle -> Trying/Done/
    Exhausted], [Selecting -> Done/Exhausted], [Done <-> Exhausted]) have
    no constructor and are therefore type-unrepresentable.  Idempotent
    self-loops are not represented (they are mutator-boundary no-ops). *)
module Cascade_transition : sig
  type ('from, 'to_) t =
    | Idle_to_selecting : (cascade_idle, cascade_selecting) t
    | Selecting_to_idle : (cascade_selecting, cascade_idle) t
    | Selecting_to_trying : (cascade_selecting, cascade_trying) t
    | Trying_to_idle : (cascade_trying, cascade_idle) t
    | Trying_to_selecting : (cascade_trying, cascade_selecting) t
    | Trying_to_done : (cascade_trying, cascade_done) t
    | Trying_to_exhausted : (cascade_trying, cascade_exhausted) t
    | Done_to_idle : (cascade_done, cascade_idle) t
    | Done_to_selecting : (cascade_done, cascade_selecting) t
    | Done_to_trying : (cascade_done, cascade_trying) t
    | Exhausted_to_idle : (cascade_exhausted, cascade_idle) t
    | Exhausted_to_selecting : (cascade_exhausted, cascade_selecting) t
    | Exhausted_to_trying : (cascade_exhausted, cascade_trying) t

  type packed = Packed_transition : ('a, 'b) t -> packed

  val to_tag : ('a, 'b) t -> string
end

(** RFC-0072 Phase 1: typed error for cascade transition spec violations.
    Each forbidden pair has its own constructor; replaces the prior
    string-formatted [Invalid_argument] payload at the validator. *)
type cascade_transition_spec_violation =
  | Idle_to_trying
  | Idle_to_done
  | Idle_to_exhausted
  | Selecting_to_done
  | Selecting_to_exhausted
  | Done_to_exhausted
  | Exhausted_to_done

val cascade_transition_spec_violation_to_tag
  :  cascade_transition_spec_violation
  -> string

(** RFC-0072 Phase 5: raised by [validate_cascade_transition] and
    [set_turn_cascade_state] on a forbidden cascade transition, carrying
    the typed [cascade_transition_spec_violation] payload (replaces the
    prior string-formatted [Invalid_argument]).  [where] is a diagnostic
    label naming the raising function.  A [Printexc] printer is registered
    so [Printexc.to_string] reproduces the original message text. *)
exception
  Cascade_transition_violation of
    { where : string
    ; from : packed_cascade_state
    ; to_ : packed_cascade_state
    ; violation : cascade_transition_spec_violation
    }

(** RFC-0072 Phase 1: resolve a (from, target) packed pair to one of
    three outcomes: a typed transition value, an idempotent no-op, or a
    typed spec violation.  Phase 2 will route [set_turn_cascade_state]
    through this resolver. *)
type cascade_resolve_outcome =
  | Resolved_transition of Cascade_transition.packed
  | Resolved_idempotent
  | Resolved_violation of cascade_transition_spec_violation

val resolve_cascade_transition
  :  from:packed_cascade_state
  -> target:packed_cascade_state
  -> cascade_resolve_outcome

(** Raises [Cascade_transition_violation] with the typed payload.
    Previously a private helper inside Keeper_registry; exposed via the
    intra-library split because [validate_cascade_transition] in
    Keeper_registry calls it after moving the exception here. *)
val raise_cascade_transition_violation
  :  where:string
  -> from:packed_cascade_state
  -> to_:packed_cascade_state
  -> violation:cascade_transition_spec_violation
  -> 'a

type compaction_stage =
  | Compaction_accumulating [@tla.idle]
  | Compaction_compacting [@tla.active]
  | Compaction_done [@tla.terminal]
[@@deriving tla]

(** {1 Compaction stage GADT infrastructure (Cycle 21 / Tier B5)} *)

type compaction_accumulating
type compaction_compacting
type compaction_done

type 'a compaction_stage_witness =
  | Compaction_accumulating : compaction_accumulating compaction_stage_witness
  | Compaction_compacting : compaction_compacting compaction_stage_witness
  | Compaction_done : compaction_done compaction_stage_witness

type packed_compaction_stage =
  | Packed : 'a compaction_stage_witness -> packed_compaction_stage

val compaction_stage_to_witness : compaction_stage -> packed_compaction_stage
val witness_to_compaction_stage : packed_compaction_stage -> compaction_stage

(** Diagnostic label using the constructor name (e.g. ["Compaction_done"]).
    Used by the [Compaction_transition_violation] [Printexc] printer. *)
val packed_compaction_stage_label : packed_compaction_stage -> string

(** RFC-0072 Phase 6: typed error for the 3 forbidden compaction-stage
    transitions (3 idempotent + 3 valid + 3 forbidden = 9 = 3×3). *)
type compaction_transition_spec_violation =
  | Accumulating_to_done
  | Done_to_accumulating
  | Done_to_compacting

val compaction_transition_spec_violation_to_tag
  :  compaction_transition_spec_violation
  -> string

(** RFC-0072 Phase 6: raised by [validate_compaction_transition] on a
    forbidden compaction transition, carrying the typed
    [compaction_transition_spec_violation] payload (replaces the prior bare
    [assert] / [Assert_failure]).  [where] is a diagnostic label naming the
    raising function.  A [Printexc] printer is registered so
    [Printexc.to_string] renders the labelled message. *)
exception
  Compaction_transition_violation of
    { where : string
    ; from : packed_compaction_stage
    ; to_ : packed_compaction_stage
    ; violation : compaction_transition_spec_violation
    }

(** Raises [Compaction_transition_violation] with the typed payload.
    Same rationale as the turn_phase / cascade raise helpers above. *)
val raise_compaction_transition_violation
  :  where:string
  -> from:packed_compaction_stage
  -> to_:packed_compaction_stage
  -> violation:compaction_transition_spec_violation
  -> 'a

type turn_measurement = {
  tm_captured_at : float;
  tm_auto_rules : Keeper_state_machine.auto_rule_summary;
}

type registry_entry = {
  base_path : string;
  name : string;
  meta : keeper_meta;
  phase : Keeper_state_machine.phase;
      (** Keeper lifecycle phase (RFC-0002 13-state machine; 11 at #5229
          → 12 with Overflowed (MASC-1) → 13 with Zombie #14707). *)
  conditions : Keeper_state_machine.conditions;
      (** Observable conditions that derive [phase]. *)
  fiber_stop : bool Atomic.t;
  fiber_wakeup : bool Atomic.t;
  event_queue : Keeper_event_queue.t Atomic.t;
      (** Event Layer queue for incoming stimuli. Independent of
          [fiber_wakeup] (which remains a hint signal). The Policy
          Layer turn must consult this queue at the start of every
          [emit] tick — see [specs/keeper-state-machine/KeeperEventQueue.tla]
          and the [TurnDequeue] action. *)
  started_at : float;
  grpc_close : (unit -> unit) option Atomic.t;
  done_p : [ `Stopped | `Crashed of string ] Eio.Promise.t;
  done_r : [ `Stopped | `Crashed of string ] Eio.Promise.u;
      (** Exposed so keeper lifecycle coordinators can resolve stop/crash exactly once.
          Callers must preserve a single terminal outcome per keeper run. *)
  restart_count : int;
  last_restart_ts : float;
  dead_since_ts : float option;
  crash_log : (float * string) list;
  last_error : string option;
  last_failure_reason : failure_reason option;
  turn_consecutive_failures : int;
  last_agent_count : int;
  board_wakeups : float StringMap.t;
  board_cursor_ts : float;
  board_cursor_post_id : string option;
  tool_usage : Keeper_types.tool_call_entry StringMap.t;
  transition_seq : int;
  waiting_for_inference : bool Atomic.t;
      (** Ephemeral flag: true when keeper is blocked in admission queue.
          Does not affect state machine phase derivation. *)
  last_auto_rules :
    (float * Keeper_state_machine.auto_rule_summary) option;
      (** Snapshot of the most recent [Context_measured] auto-rule summary.
          Stored as [(wall_clock, summary)] so the composite observer
          (RFC-0003 §6) can surface the last measurement without reading
          history files. [None] until the first [Context_measured] event
          has been dispatched. *)
  last_event_bus_correlation : string option;
      (** Most recent OAS Event_bus [correlation_id] extracted after a
          keeper turn via [Event_bus.drain]. [None] until the first
          successful drain. Stable per session (= [meta.runtime.trace_id]
          as passed to OAS). *)
  pending_turn_measurement : turn_measurement option;
      (** Fresh measurement captured by [Context_measured] and reserved
          for the next [mark_turn_measurement] call. Hidden from idle
          observers so the composite snapshot stays turn-scoped. *)
  current_turn_observation : turn_observation option;
      (** Live, turn-scoped observation record (issue #7122 Phase 1).
          [Some _] while a turn is actively executing. [None] outside
          any turn. Anti-stale barrier: sub-FSM live states are only
          observable while [Some]. *)
  last_completed_turn : completed_turn_observation option;
      (** Frozen snapshot of the most recently completed turn
          (RFC-0003 Phase 2 design A3). Populated by
          [mark_turn_finished] when [current_turn_observation] is
          [Some]; carries terminal data for the composite observer's
          [last_outcome] snapshot field.

          Distinct from [current_turn_observation] so the observer
          can distinguish "live in-turn state" from "previous turn
          result": idle keepers never surface stale terminal states
          on the live sub-FSM fields, but operators can still see
          the most recent outcome in [last_outcome]. *)
  last_skip_observation : (float * string list) option;
      (** Most recent [keeper_cycle_decision] skip outcome captured by
          the keepalive loop (#10940 follow-up).  The [Prometheus]
          [proactive_skip_reason_metric] aggregates skip reasons over
          time, but at stale-watchdog kill the operator wants to see
          *which* reasons were active *just before* the 300s idle
          timeout fired.  [Some (ts, reasons)] = wall clock + verdict
          reason strings ([cooldown_pending], [no_signal],
          [scheduled_autonomous_disabled], etc.) from the last skip;
          [None] until the first skip is observed.  Read by
          [Keeper_stale_watchdog] to enrich the kill warn line so an
          [idle_stale=true] termination is no longer indistinguishable
          from a *stuck* fiber. *)
  compaction_stage : packed_compaction_stage;
      (** Explicit KMC projection owned by the runtime, not derived from
          parent phase on read. This lets the observer surface
          [done] without guessing from conditions. *)
}

and turn_observation = {
  turn_id : int;
      (** Per-keeper turn counter at turn start (matches
          [meta.runtime.usage.total_turns] + 1). *)
  started_at : float;
      (** Unix timestamp when this turn record was installed. *)
  last_progress_at : float;
      (** Unix timestamp of the most recent in-turn progress signal.
          Initialized to [started_at] and updated by registry transitions,
          SDK streaming events, and completed tool calls. *)
  last_progress_kind : string option;
      (** Low-cardinality label for the progress signal that most recently
          refreshed [last_progress_at]. *)
  turn_phase : packed_turn_phase;
  decision_stage : packed_decision_stage;
  cascade_state : packed_cascade_state;
  measurement : turn_measurement option;
  measurement_bind_count : int;
      (** Number of [Context_measured] snapshots bound to this live turn.
          The composite observer's [event_priority_monotone] invariant
          requires this to stay <= 1. *)
  selected_model : string option;
}

and completed_turn_observation = {
  ct_turn_id : int;
  ct_started_at : float;
  ct_ended_at : float;
  ct_decision_stage : packed_decision_stage;
  ct_cascade_state : packed_cascade_state;
  ct_selected_model : string option;
}

(** Resolve a keeper run completion promise at most once.
    Returns [false] if another fiber won the resolve race. *)
val try_resolve_done :
  registry_entry -> [ `Stopped | `Crashed of string ] -> bool

(** Internal: keeper registry key composition (base_path ^ \\x1f ^ name).
    Exposed via mli so keeper_registry.ml's state functions can use it
    after the intra-library split; not intended for external callers. *)
val registry_key : base_path:string -> string -> string

(** Pure mapping from cascade_state witness to its parent turn_phase
    witness. Used by composite observer derivations. *)
val turn_phase_of_cascade_state :
  packed_cascade_state -> packed_turn_phase

(** Classify a live turn_observation into a completed_turn_outcome
    using exhaustive pattern matching on (decision_stage, cascade_state).
    Pure function, no state access. *)
val completed_turn_outcome_of_observation :
  turn_observation -> Keeper_transition_audit.completed_turn_outcome

(** Dispatch origin for paired post-turn lifecycle events.

    [Compaction_started]/[Compaction_completed]/[Compaction_failed] and
    [Handoff_started]/[Handoff_completed]/[Handoff_failed] are same-turn
    lifecycle pairs. The registry rejects them from [Generic_dispatch] so
    keepalive/guard/manual callers cannot emit half of a pair outside the
    owner path. *)
type lifecycle_event_origin =
  | Generic_dispatch
  | Post_turn_lifecycle
  | Operator_compact

(** Pure converter for diagnostic / log labels. *)
val lifecycle_event_origin_to_string : lifecycle_event_origin -> string

(** Internal: predicate over [Keeper_state_machine.event] identifying the
    compaction- and handoff-pair half-events. *)
val is_paired_lifecycle_event : Keeper_state_machine.event -> bool

(** Pure dispatch-origin gate: returns true iff the (origin, event) pair
    is allowed under the paired-lifecycle invariant. *)
val origin_allows_paired_lifecycle_event :
  lifecycle_event_origin -> Keeper_state_machine.event -> bool

(** Pure: derive the next [pending_turn_measurement] field after observing
    [event] at wall-clock [now], preserving the prior value when the event
    is not a [Context_measured]. *)
val pending_measurement_after_event :
  float -> registry_entry -> Keeper_state_machine.event -> turn_measurement option

(** Pure: derive the next [compaction_stage] after observing [event],
    preserving the entry's prior stage on non-compaction events. *)
val compaction_stage_of_event :
  registry_entry -> Keeper_state_machine.event -> packed_compaction_stage
