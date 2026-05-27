(** Keeper Execution Receipt — turn-level receipt record and classification.

    All type definitions ([outcome_kind], [error_kind], [tool_contract_result],
    [t], etc.) and their pure converters live in
    {!Keeper_execution_receipt_types}. Re-exported here so callers can
    continue using [Keeper_execution_receipt.t] etc. without reaching into
    the types submodule.

    {1 SSOT Types} *)
include module type of struct
  include Keeper_execution_receipt_types
end

(** {1 Operator disposition} *)

(** Operator-facing classification of a finished turn. Closed set.

    Producer is [operator_disposition]; consumers
    ([needs_operator_broadcast], dashboard JSON, broadcast payload)
    pattern-match exhaustively. The wire form is byte-compatible with the
    pre-typing string ([operator_disposition_kind_to_string]). *)
type operator_disposition_kind =
  | Disp_pass
  | Disp_pause_human
  | Disp_alert_exhausted
  | Disp_fail_open_next_cascade
  | Disp_pass_next_model
  | Disp_user_cancelled
  | Disp_skipped
  | Disp_unknown

val operator_disposition_kind_to_string : operator_disposition_kind -> string

(** Reason paired with [operator_disposition_kind]. Closed set; the wire
    form is byte-compatible with the pre-typing string. *)
type operator_disposition_reason =
  | Reason_healthy
  | Reason_cascade_exhausted
  | Reason_preflight_config_error
  | Reason_degraded_retry
  | Reason_cascade_fallback
  | Reason_provider_runtime_error
  | Reason_internal_error
  | Reason_tool_required_unsatisfied
  | Reason_tool_route_recoverable_failure
  | Reason_turn_livelock_blocked
  | Reason_cancelled
  | Reason_phase_skipped
  | Reason_unmapped_cascade_state

val operator_disposition_reason_to_string : operator_disposition_reason -> string

(** Derived display pair (disposition, reason) computed from receipt fields.
    Exposed for test access; the runtime path consumes it via [append]. *)
val operator_disposition : t -> operator_disposition_kind * operator_disposition_reason

(** [needs_operator_broadcast disposition] returns true when the disposition
    indicates a silent dead-end that operators must be notified about. *)
val needs_operator_broadcast : operator_disposition_kind -> bool

(** {1 Own-module vals} *)

val to_json : t -> Yojson.Safe.t

(** Structured payload emitted for [keeper.operator_broadcast_required].
    Exposed so tests can pin the diagnostic fields operators need when a
    keeper turn pauses or stalls silently. *)
val operator_broadcast_payload
  :  t
  -> disposition:operator_disposition_kind
  -> reason:operator_disposition_reason
  -> Yojson.Safe.t

(** Structured watchdog payload. Keeps the exact [stale_seconds] while
    exposing low-cardinality failure/cohort fields for dashboards and issue
    aggregation. *)
val stale_broadcast_payload
  :  keeper_name:string
  -> agent_name:string
  -> cascade_name:Cascade_name.t
  -> trace_id:string
  -> generation:int
  -> failure_reason:Keeper_registry.failure_reason option
  -> stale_seconds:float
  -> last_turn_ts:float
  -> Yojson.Safe.t

val append : Coord.config -> t -> unit
val latest_json : Coord.config -> string -> Yojson.Safe.t option
val latest_json_by_keeper : Coord.config -> string list -> (string * Yojson.Safe.t) list

(** Emit a watchdog-sourced operator_broadcast_required event for a keeper
    that has been Running but not produced a turn within the stale
    threshold. Used by the supervisor watchdog fiber (Step 3 of the
    keeper-pause-broadcast-watchdog change) to convert silent stalls into
    addressable events. *)
val emit_stale_keeper_broadcast
  :  Coord.config
  -> keeper_name:string
  -> agent_name:string
  -> cascade_name:Cascade_name.t
  -> trace_id:string
  -> generation:int
  -> failure_reason:Keeper_registry.failure_reason option
  -> stale_seconds:float
  -> last_turn_ts:float
  -> unit
