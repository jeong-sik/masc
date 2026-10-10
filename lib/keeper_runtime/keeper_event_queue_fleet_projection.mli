(** Pure fleet projection of already acquired durable queue and owner facts.
    This module performs no owner lookup, filesystem access or lifecycle callback. *)

type queue_residence_unknown_reason =
  | First_admission_not_recorded
  | Queue_observation_incomplete
      (** Queue storage observation is unavailable/incomplete. *)

type queue_residence = Unknown of queue_residence_unknown_reason
(** Diagnostic evidence only. Persisted queue entries do not record their first
    admission time. Source timestamps, revisions and file mtimes cannot supply
    it, including for an empty queue or a newly observed pending entry. *)

val queue_residence_to_yojson : queue_residence -> Yojson.Safe.t
(** The unknown residence duration is JSON null, with an explicit reason. *)

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
