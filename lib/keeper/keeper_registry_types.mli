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

include module type of Keeper_registry_types_failure
include module type of Keeper_registry_types_turn_phase
include module type of Keeper_registry_types_decision
include module type of Keeper_registry_types_compaction

type turn_measurement = {
  tm_captured_at : float;
  tm_auto_rules : Keeper_state_machine.auto_rule_summary;
}

type done_resolution = [ `Stopped | `Crashed of string ]

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
  done_p : done_resolution Eio.Promise.t;
  done_r : done_resolution Eio.Promise.u;
      (** Completion resolver owned by {!resolve_done}. Runtime callers must
          not resolve this field directly; use {!resolve_done} so
          double-resolve races return the prior terminal outcome. *)
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
          the keepalive loop (#10940 follow-up).  The [Otel_metric_store]
          [proactive_skip_reason_metric] aggregates skip reasons over
          time, but operators need recent skip verdict context when
          diagnosing idle/quiet keepers. [Some (ts, reasons)] = wall
          clock + verdict
          reason strings ([cooldown_pending], [no_signal],
          [scheduled_autonomous_disabled], etc.) from the last skip;
          [None] until the first skip is observed. *)
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
  ct_selected_model : string option;
}

type done_resolve_result =
  | Done_resolved of { source : string }
  | Done_already_resolved of {
      source : string;
      previous : done_resolution;
    }

(** Resolve a keeper run completion promise at most once.

    [source] identifies the lifecycle branch attempting the resolve. The
    function never raises on a double-resolve race; instead it returns the
    already-resolved outcome. *)
val resolve_done :
  registry_entry -> source:string -> done_resolution -> done_resolve_result

(** Internal: keeper registry key composition (base_path ^ \\x1f ^ name).
    Exposed via mli so keeper_registry.ml's state functions can use it
    after the intra-library split; not intended for external callers. *)
val registry_key : base_path:string -> string -> string

(** Classify a live turn_observation into a completed_turn_outcome
    using exhaustive pattern matching on (decision_stage, turn_phase).
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
