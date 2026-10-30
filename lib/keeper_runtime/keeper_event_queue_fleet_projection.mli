(** Pure fleet projection of already acquired durable queue and owner facts.
    This module performs no owner lookup, filesystem access or lifecycle callback. *)

type queue_residence_unknown_reason =
  | First_admission_not_recorded
  | Queue_observation_incomplete
      (** Queue storage observation is unavailable/incomplete. *)
  | Clock_observation_invalid
      (** Non-finite clock or observation preceding a recorded admission. *)

type queue_residence =
  | Empty
  | Observed of { oldest_admitted_at : float; oldest_age_seconds : float }
  | Unknown of queue_residence_unknown_reason
(** Diagnostic evidence only. Observed duration requires complete finite
    admission evidence and a clock not preceding any admission. Empty has no
    duration; missing/incomplete evidence stays unknown. *)

val queue_residence_of_selections :
  now:float -> complete:bool -> Keeper_event_queue_state.pending_selection list -> queue_residence
val queue_residence_of_yojson : Yojson.Safe.t -> queue_residence option
(** Strict typed presentation decoder; malformed state/number combinations
    return [None]. It does not establish measurement authority by itself. *)

val queue_residence_to_yojson : queue_residence -> Yojson.Safe.t
(** Empty/unknown duration is JSON null; observed duration has its admission
    timestamp. These observations never authorize queue or Keeper transitions. *)

type owner_lifecycle =
  | Runnable
  | Recoverable
  | Retained_disabled
  | Paused_dead
  | Shutdown_fenced
  | Lifecycle_unknown of string

type keeper_summary

val keeper_summary_of_state :
  keeper_name:string -> owner_lifecycle:owner_lifecycle ->
  Keeper_event_queue_state.t -> keeper_summary

val keeper_summary_unavailable :
  keeper_name:string -> owner_lifecycle:owner_lifecycle ->
  read_errors:string list -> keeper_summary

val fleet_summary_json :
  now:float -> base_path:string -> discovery_error:string option ->
  keeper_summary list -> Yojson.Safe.t
(** [base_path] is the caller's selected canonical projection path, or the
    original path when canonicalization failed. Discovery and queue read
    errors remain visible; source age does not invent queue residence age. *)
