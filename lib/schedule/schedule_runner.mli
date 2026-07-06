(** Due scanner, generic wake-signal feed, and optional consumer dispatch for
    scheduled automation.

    This module refreshes due schedule state and emits durable generic schedule
    signals. When a consumer is installed, dispatch remains consumer-opaque and
    the store records only generic execution evidence. *)

type signal_kind =
  | Due_candidate
  | Due_blocked_approval

type wake_signal =
  { signal_id : string
  ; kind : signal_kind
  ; schedule_id : string
  ; emitted_at : float
  ; due_at : float
  ; risk_class : Schedule_domain.risk_class
  ; payload_digest : string
  ; payload : Yojson.Safe.t
  }

type wake_signal_read_error_kind =
  | Wake_signal_json_parse_error
  | Wake_signal_schema_decode_error

type wake_signal_read_error =
  { ordinal : int
  ; kind : wake_signal_read_error_kind
  ; error : string
  }

type wake_signal_read_result =
  { signals : wake_signal list
  ; errors : wake_signal_read_error list
  }

type tick_result =
  { due_changed : int
  ; emitted : wake_signal list
  ; rescheduled : int
  ; dispatches : dispatch_result list
  }

and dispatch_status =
  | Dispatch_succeeded
  | Dispatch_failed
  | Dispatch_unsupported
  | Dispatch_start_rejected

and dispatch_result =
  { schedule_id : string
  ; status : dispatch_status
  ; detail : Yojson.Safe.t option
  ; error : string option
  ; duration_sec : float
  }

type consumer =
  { accepts : Schedule_domain.schedule_request -> (unit, string) result
  ; dispatch :
      Workspace_utils.config ->
      now:float ->
      Schedule_domain.schedule_request ->
      (Yojson.Safe.t, string) result
  }

type dispatch_wrapper =
  Schedule_domain.schedule_request -> (unit -> dispatch_result) -> dispatch_result
(** Optional composition-root hook around one dispatch attempt. The runner
    stays telemetry-agnostic; server code can use this to add spans without
    moving Otel policy into the schedule library. *)

type runner_error =
  | Service_error of Schedule_service.service_error
  | Signal_store_error of string

val runner_error_to_string : runner_error -> string

val signal_kind_to_string : signal_kind -> string
val signal_kind_of_string : string -> (signal_kind, string) result
val wake_signal_read_error_kind_to_string : wake_signal_read_error_kind -> string
val dispatch_status_to_string : dispatch_status -> string

val signals_dir : Workspace_utils.config -> string
val signal_seen_path : Workspace_utils.config -> string

val wake_signal_to_yojson : wake_signal -> Yojson.Safe.t
val wake_signal_of_yojson : Yojson.Safe.t -> (wake_signal, string) result

val read_recent_signals :
  Workspace_utils.config -> int -> wake_signal list
(** Compatibility wrapper over {!read_recent_signals_with_errors}. Decode
    errors are omitted from the returned list but logged and counted by
    [masc_schedule_signal_read_error_total]; dashboard/diagnostic callers
    should use the Result-carrying read model below. *)

val read_recent_signals_with_errors :
  Workspace_utils.config -> int -> wake_signal_read_result
(** Read at most [n] recent durable wake-signal rows in chronological order,
    preserving per-row JSON/schema decode failures instead of silently dropping
    malformed records. *)

val tick :
  ?dispatch_wrapper:dispatch_wrapper ->
  ?consumer:consumer ->
  Workspace_utils.config ->
  now:float ->
  (tick_result, runner_error) result
(** Refresh due state and append at-most-once generic wake signals for newly
    observable due work or due approval blockers. Recurring due work is advanced
    after the generic due signal path succeeds when no consumer is installed; a
    consumer dispatch can instead complete/fail the request. Consumer payload
    rejection is recorded as a failed execution instead of leaving the request
    due forever. *)

module For_testing : sig
  val write_seen : Workspace_utils.config -> string list -> (unit, string) result
end
