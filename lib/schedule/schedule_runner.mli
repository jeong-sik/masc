(** Due scanner, generic wake-signal feed, and optional consumer dispatch for
    scheduled automation.

    This module refreshes due schedule state and emits durable generic schedule
    signals. When a consumer is installed, dispatch remains consumer-opaque and
    the store records only generic execution evidence. *)

type signal_kind =
  | Due_candidate

type wake_signal =
  { occurrence_id : Schedule_occurrence_id.t
  ; kind : signal_kind
  ; schedule_id : string
  ; emitted_at : float
  ; due_at : float
  ; payload_digest : string
  ; payload : Yojson.Safe.t
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
  { occurrence_id : Schedule_occurrence_id.t
  ; schedule_id : string
  ; status : dispatch_status
  ; detail : Yojson.Safe.t option
  ; error : string option
  }

type consumer_dispatch_error =
  | Retryable_dispatch_failure of string
  | Terminal_dispatch_rejection of string

type consumer =
  { accepts : Schedule_domain.schedule_request -> (unit, string) result
  ; dispatch :
      Workspace_utils.config ->
      now:float ->
      wake_signal ->
      Schedule_domain.schedule_request ->
      (Yojson.Safe.t, consumer_dispatch_error) result
  }

type runner_error =
  | Service_error of Schedule_service.service_error
  | Signal_store_error of string

val runner_error_to_string : runner_error -> string

val signal_kind_to_string : signal_kind -> string
val signal_kind_of_string : string -> (signal_kind, string) result
val dispatch_status_to_string : dispatch_status -> string

val signals_dir : Workspace_utils.config -> string
val signal_seen_path : Workspace_utils.config -> string

val wake_signal_to_yojson : wake_signal -> Yojson.Safe.t
val wake_signal_of_yojson : Yojson.Safe.t -> (wake_signal, string) result

val read_recent_signals :
  Workspace_utils.config -> int -> (wake_signal list, string) result
(** Read at most [n] recent durable wake signals in chronological order.
    Malformed persisted rows are returned as an explicit decode error. *)

val tick :
  ?consumer:consumer ->
  Workspace_utils.config ->
  now:float ->
  (tick_result, runner_error) result
(** Refresh due state and append at-most-once generic wake signals for newly
    observable due work. Recurring due work is advanced
    after the generic due signal path succeeds when no consumer is installed; a
    consumer dispatch can instead complete/fail the request. Consumer payload
    rejection is terminal. A typed retryable dispatch failure finishes only its
    current execution attempt and leaves the schedule [Due] for the next tick. *)
