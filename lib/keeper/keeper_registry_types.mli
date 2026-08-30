(** Keeper_registry_types — pure type definitions extracted from
    Keeper_registry (3041 LoC godfile).

    Holds the [failure_reason] cluster + pure converters. State-mutating
    operations remain in Keeper_registry. Re-included by Keeper_registry
    so existing 126 callers continue to use [Keeper_registry.failure_reason]
    unchanged. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

module StringMap : Map.S with type key = string

(** Issue #18901: cause carried inside [Fiber_unresolved]. Splits the
    24h fleet ratio of 26 graceful-shutdown artifacts to 9 real
    missed-resolutions inside the same supervisor crash log. *)
type fiber_drop_cause =
  | Graceful_shutdown
  | Cancelled_by_parent
  | Unexpected

type failure_reason =
  | Heartbeat_consecutive_failures of int
  | Turn_consecutive_failures of int
  | Stale_termination_storm of { count : int }
      (** #10765 Phase 2: latched when [record_stale_termination] returns a
          window count >= [escalation_threshold]. The supervisor's
          [`Crashed] branch checks this variant and skips [to_restart],
          persisting [meta.paused = true] instead so an operator must
          investigate the underlying runtime/provider/fd issue before
          resuming the keeper. *)
  | Provider_runtime_error of
      { code : string
      ; detail : string
      ; provider_id : string option
      ; http_status : int option
      ; runtime_id : string option
      ; agent_core_timeout : Keeper_turn_terminal_code.agent_core_timeout option
      ; reason : Keeper_meta_contract.runtime_exhaustion_reason option
      }
      (** Latched from the keeper turn terminal reason when the provider,
          adapter, or runtime fails before useful keeper progress. A later
          idle watchdog should preserve this root cause instead of recasting
          the keeper as generically stale. *)
  | Turn_configuration_error of
      { code : string
      ; field : string option
      ; detail : string
      }
      (** Latched from a typed Agent Core configuration error. The current
          process cannot repair this failure without an operator changing
          configuration or environment. *)
  | Fiber_unresolved of fiber_drop_cause
  | Exception of string
  | Turn_overflow_failure
      (** Context-overflow compact-retry exhaustion observed for the current
          turn. It does not change Keeper lifecycle state. *)
  | Operator_interrupt
      (** The current turn was cancelled by an explicit operator request,
          typically from the dashboard "stop current turn" action. *)

exception Operator_interrupt
(** Raised by [interrupt_current_turn] to cancel the live turn switch.
    Fibers inside the turn switch observe it as
    [Eio.Cancel.Cancelled Operator_interrupt]; the [Eio.Switch.run] boundary
    re-raises it BARE. Classification ladders must handle both forms
    (#28810: the bare form used to fall into generic internal-error arms). *)

val operator_interrupt_detail : string
(** Human-facing detail for [Operator_interrupt] terminals. One shared string
    so ledger rows, queued outcomes, and tool responses classify as one
    incident class. *)

val is_operator_interrupt : exn -> bool
(** Whether [exn] reduces to {!Operator_interrupt} through every wrapper
    shape Eio can deliver: bare, [Eio.Cancel.Cancelled],
    [Fun.Finally_raised], and [Eio.Exn.Multiple] (only when every member
    reduces). Classification ladders must use this rather than matching the
    constructor directly (#28868 review: constructor-only arms missed the
    combined shapes). *)

val failure_reason_to_string : failure_reason -> string

(** #10584: cohort key for grouping failures by variant (ignores
    parameters). [None] returns ["unknown"]. New variants added to
    [failure_reason] force a same-PR update of this function via
    OCaml's exhaustive-match check — Option B mitigation for the
    recurring P0 pattern (#10490, #10574). *)

(** Pure control-flow signal for immediate fiber termination (RFC-0002).
    Carries no state — failure reason must be pre-stored via
    [set_failure_reason] before raising. *)
exception Keeper_fiber_crash
type turn_phase =
  | Turn_idle [@tla.idle]
  | Turn_prompting [@tla.active]
  | Turn_routing [@tla.active]
  | Turn_executing [@tla.active]
  | Turn_finalizing [@tla.active]
  | Turn_exhausted [@tla.terminal]
[@@deriving tla]

(** {1 Turn phase GADT infrastructure (Cycle 21 / Tier B5)} *)

type turn_idle
type turn_prompting
type turn_routing
type turn_executing
type turn_finalizing
type turn_exhausted

type 'a turn_phase_witness =
  | Turn_idle : turn_idle turn_phase_witness
  | Turn_prompting : turn_prompting turn_phase_witness
  | Turn_routing : turn_routing turn_phase_witness
  | Turn_executing : turn_executing turn_phase_witness
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
    [Runtime_transition].  Enumerates the 23 valid cross-state transitions
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
    | Executing_to_finalizing : (turn_executing, turn_finalizing) t
    | Executing_to_exhausted : (turn_executing, turn_exhausted) t
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
  | Idle_to_finalizing
  | Idle_to_exhausted
  | Prompting_to_idle
  | Routing_to_idle
  | Routing_to_finalizing
  | Executing_to_idle
  | Finalizing_to_idle
  | Exhausted_to_idle
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
    outcomes.  Mirrors [resolve_runtime_transition]. *)
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
  | Decision_tool_policy_selected [@tla.active]
[@@deriving tla]

(** {1 Decision stage GADT infrastructure (Cycle 21 / Tier B5)} *)

type decision_undecided
type decision_guard_ok
type decision_tool_policy_selected

type 'a decision_stage_witness =
  | Decision_undecided : decision_undecided decision_stage_witness
  | Decision_guard_ok : decision_guard_ok decision_stage_witness
  | Decision_tool_policy_selected : decision_tool_policy_selected decision_stage_witness

type packed_decision_stage = Packed : 'a decision_stage_witness -> packed_decision_stage

val witness_to_stage : 'a decision_stage_witness -> decision_stage
val stage_to_witness : decision_stage -> packed_decision_stage

(** Decision stages valid as ADVANCE targets within a turn.  Excludes
    [Decision_undecided] (the initial state set only by [mark_turn_started]
    / [mark_agent_core_turn_started]).  The 2 spec-forbidden [<active>_to_undecided]
    transitions are unrepresentable through this type, replacing the prior
    runtime [invalid_arg] inside [set_turn_decision_stage]. *)
type decision_stage_active =
  | Decision_active_guard_ok
  | Decision_active_tool_policy_selected

val decision_stage_active_to_packed
  :  decision_stage_active
  -> packed_decision_stage

(** Diagnostic label using the constructor name (e.g.
    ["Decision_guard_ok"]).  Used by [validate_runtime_transition] /
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
    | Undecided_to_tool_policy_selected : (decision_undecided, decision_tool_policy_selected) t
    | Guard_ok_to_tool_policy_selected : (decision_guard_ok, decision_tool_policy_selected) t
    | Tool_policy_selected_to_guard_ok : (decision_tool_policy_selected, decision_guard_ok) t

  val to_tag : ('from, 'to_) t -> string
end

type turn_attempt_state = {
  turn_id : int;
  attempts : int;
  first_started_at : float;
}

(** What entered a turn: its exact consumed event batch, an empty external
    wake, the proactive cadence tick, or an operator/connector chat message.
    Closed over {!Keeper_event_queue.stimulus_payload} so a new source cannot
    silently collapse into a generic "running" label on the operator
    dashboard. *)
type wake_reason =
  | Proactive_tick
  | Woken of Keeper_event_queue.stimulus_payload list
  | Chat_request
      (** The chat lane ({!Keeper_turn.run_keeper_invocation_turn_admitted})
          entered the turn. It carries no stimulus payload: a chat turn is
          claimed from the Owner's durable operation ledger, not selected from
          the event queue, so there is nothing in
          {!Keeper_event_queue.stimulus_payload} that describes it. Distinct
          from [Proactive_tick] because a chat turn is requested, not scheduled
          — collapsing the two would report an operator's message as autonomous
          activity. *)

val wake_reason_label : wake_reason -> string
(** Stable low-cardinality label: ["proactive_tick"], ["woken"], or
    ["chat_request"]. Use {!Keeper_event_queue.payload_kind_label} on the
    carried stimuli (for [Woken]) to surface the finer-grained wake cause. *)

type turn_measurement = {
  tm_captured_at : float;
  tm_context_actions : Keeper_state_machine.context_actions;
}

type done_resolution = [ `Stopped | `Crashed of string ]

type lifecycle_transaction_purpose =
  | Paused_work_disposition
  | Keepalive_launch

type lifecycle_reservation_snapshot =
  { owner_id : string
  ; purpose : lifecycle_transaction_purpose
  }

type registry_entry = {
  base_path : string;
      (** Canonical workspace identity from
          {!Config_dir_resolver.canonical_base_path}; byte-equal to the
          BasePath segment embedded by {!registry_key}. *)
  name : string;
  meta : keeper_meta;
  phase : Keeper_state_machine.phase;
      (** Raw Keeper lifecycle phase. *)
  conditions : Keeper_state_machine.conditions;
      (** Observable conditions that derive [phase]. *)
  fiber_stop : bool Atomic.t;
  fiber_wakeup : bool Atomic.t;
  cadence_sleeping : bool Atomic.t;
      (** Ephemeral sleep handshake for runtime cadence decreases. [true]
          only while the heartbeat fiber is inside its inter-cycle sleep. A
          cadence wake consumes it with CAS, so active pre-turn work cannot
          queue an extra paid cycle. *)
  event_queue : Keeper_event_queue.t Atomic.t;
      (** Event Layer queue for incoming stimuli. Independent of
          [fiber_wakeup] (which remains a hint signal). The Policy
          Layer turn must consult this queue at the start of every
          [emit] tick — see [specs/keeper-state-machine/KeeperEventQueue.tla]
          and the [TurnDequeue] action. *)
  started_at : float;
  grpc_close : (unit -> unit) option Atomic.t;
  lane : Keeper_lane.t;
      (** Structured-concurrency scope owned by this exact registry entry.
          Its exit promise is the authoritative lane join signal. *)
  done_p : done_resolution Eio.Promise.t;
  done_r : done_resolution Eio.Promise.u;
      (** Completion resolver owned by {!resolve_done}. Runtime callers must
          not resolve this field directly; use {!resolve_done} so
          double-resolve races return the prior terminal outcome. *)
  restart_count : int;
  last_restart_ts : float;
  crash_log : (float * string) list;
  last_error : string option;
  last_failure_reason : failure_reason option;
  turn_consecutive_failures : int;
  turn_attempt_state : turn_attempt_state option Atomic.t;
      (** Objective per-Keeper turn-attempt history, updated via CAS on this
          per-entry atomic. This observation never controls dispatch. *)
  current_turn_switch : Eio.Switch.t option Atomic.t;
      (** Live turn-scoped switch exposed for operator interrupt.
          [Some sw] while a turn is running; [None] otherwise. *)
  board_wakeups : float StringMap.t;
  board_cursor_ts : float;
  board_cursor_post_id : string option;
  tool_usage : Keeper_types.tool_call_entry StringMap.t;
  transition_seq : int;
  waiting_for_inference : bool Atomic.t;
      (** Ephemeral flag: true when keeper is blocked in admission queue.
          Does not affect state machine phase derivation. *)
  last_context_actions :
    (float * Keeper_state_machine.context_actions) option;
      (** Snapshot of the most recent [Context_measured] auto-rule summary.
          Stored as [(wall_clock, summary)] so the composite observer
          (RFC-0003 §6) can surface the last measurement without reading
          history files. [None] until the first [Context_measured] event
          has been dispatched. *)
  last_event_bus_correlation : string option;
      (** Most recent AGENT_CORE Event_bus [correlation_id] extracted after a
          keeper turn via [Event_bus.drain]. [None] until the first
          successful drain. Stable per session (= [meta.runtime.trace_id]
          as passed to AGENT_CORE). *)
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
          the keepalive loop (#10940 follow-up).  The [Otel_metric_store]
          proactive skip counter aggregates skip reasons over time, but
          operators need recent skip verdict context when diagnosing
          idle/quiet keepers. [Some (ts, reasons)] = wall clock + verdict
          reason strings ([keeper_paused], [reactive_disabled],
          [scheduled_autonomous_disabled]) from the last skip;
          [None] until the first skip is observed. *)
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
          Agent Core streaming events, and completed tool calls. *)
  last_progress_kind : string option;
      (** Low-cardinality label for the progress signal that most recently
          refreshed [last_progress_at]. *)
  active_tool_count : int;
      (** Write-through mirror of the turn event bus [pending_tool_count]
          (tools issued but not yet completed). Maintained from the
          authoritative FSM via [record_turn_tool_inflight]; the supervisor
          sweep reads it to exclude active tool execution from the
          [Mid_turn_no_progress] no-progress window (RFC-0197 points 2-3).
          [0] outside any tool call. *)
  turn_phase : packed_turn_phase;
  decision_stage : packed_decision_stage;
  measurement : turn_measurement option;
  measurement_bind_count : int;
      (** Number of [Context_measured] snapshots bound to this live turn.
          The composite observer's [event_priority_monotone] invariant
          requires this to stay <= 1. *)
  selected_model : string option;
  wake : wake_reason;
      (** What triggered this turn (#16, 38-bug campaign PR-5). Installed
          once by [mark_turn_started] and frozen for the turn's lifetime. *)
}

and completed_turn_observation = {
  ct_turn_id : int;
  ct_started_at : float;
  ct_ended_at : float;
  ct_decision_stage : packed_decision_stage;
  ct_selected_model : string option;
  ct_wake : wake_reason;
      (** Frozen copy of [turn_observation.wake] (#16, 38-bug campaign
          PR-5), so the "what just finished" surface can show why the
          last turn ran, not only the live one. *)
}

type done_resolve_result =
  | Done_resolved of { source : string }
  | Done_already_resolved of {
      source : string;
      previous : done_resolution;
    }

(** Structured health verdict for a registry entry.  Used both as the public
    [health_of_entry] / [get_with_health] result and as the validation-error
    type returned by [validate_registry_entry] and the CAS write helpers. *)
type registry_entry_health =
  | Healthy
  | Lifecycle_transaction_reserved of lifecycle_reservation_snapshot
  | Meta_validation_failed of { reason : string }
  | Required_field_missing of { field : string }
  | Base_path_mismatch of { expected : string; actual : string }
  | Name_mismatch of { expected : string; actual : string }

(** Alias kept so the CAS write helpers can return
    [(unit, registry_entry_validation_error) result] without duplicating the
    health variant. *)
type registry_entry_validation_error = registry_entry_health

(** Resolve a keeper run completion promise at most once.

    [source] identifies the lifecycle branch attempting the resolve. The
    function never raises on a double-resolve race; instead it returns the
    already-resolved outcome. *)
val resolve_done :
  registry_entry -> source:string -> done_resolution -> done_resolve_result

val lane_has_exited : registry_entry -> bool

(** Internal: canonicalize a caller-provided BasePath through the shared
    {!Config_dir_resolver.canonical_base_path} identity. Invalid paths raise
    [Invalid_argument]; registry APIs require a valid workspace identity. *)
val canonical_base_path_exn : string -> string

(** Internal: keeper registry key composition
    (canonical_base_path ^ \\x1f ^ name). Exposed via mli so
    keeper_registry.ml's state functions can use it after the intra-library
    split; not intended for external callers. *)
val registry_key : base_path:string -> string -> string

(** Internal: inverse of [registry_key]. Returns the [base_path] and
    keeper [name] embedded in a registry key, or an error if the key
    contains no unit separator. *)
val registry_key_parts : string -> (string * string, string) result

(** Classify a live turn_observation into a completed_turn_outcome
    using exhaustive pattern matching on (decision_stage, turn_phase).
    Pure function, no state access. *)
val completed_turn_outcome_of_observation :
  turn_observation -> Keeper_transition_audit.completed_turn_outcome

(** Dispatch origin for post-turn lifecycle events. *)
type lifecycle_event_origin =
  | Generic_dispatch
  | Post_turn_lifecycle

(** Pure converter for diagnostic / log labels. *)
val lifecycle_event_origin_to_string : lifecycle_event_origin -> string

(** Pure: derive the next [pending_turn_measurement] field after observing
    [event] at wall-clock [now], preserving the prior value when the event
    is not a [Context_measured]. *)
val pending_measurement_after_event :
  float -> registry_entry -> Keeper_state_machine.event -> turn_measurement option
