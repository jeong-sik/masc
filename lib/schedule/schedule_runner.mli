(** Due scanner and generic wake-signal feed for scheduled automation.

    This module does not dispatch work and does not know consumer domains. It
    refreshes due schedule state, emits durable generic schedule signals, and
    leaves interpretation to consumers. *)

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

type tick_result =
  { due_changed : int
  ; emitted : wake_signal list
  }

type runner_error =
  | Service_error of Schedule_service.service_error
  | Signal_store_error of string

val runner_error_to_string : runner_error -> string

val signal_kind_to_string : signal_kind -> string
val signal_kind_of_string : string -> (signal_kind, string) result

val signals_dir : Workspace_utils.config -> string
val signal_seen_path : Workspace_utils.config -> string

val wake_signal_to_yojson : wake_signal -> Yojson.Safe.t
val wake_signal_of_yojson : Yojson.Safe.t -> (wake_signal, string) result

val read_recent_signals :
  Workspace_utils.config -> int -> wake_signal list
(** Read at most [n] recent durable wake signals in chronological order. *)

val tick :
  Workspace_utils.config -> now:float -> (tick_result, runner_error) result
(** Refresh due state and append at-most-once generic wake signals for newly
    observable due work or due approval blockers. No consumer is invoked. *)
