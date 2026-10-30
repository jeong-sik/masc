(** Channel_gate_metrics -- connector diagnostics, outcomes, latency, and status.

    Thread-safe via [Eio_guard.with_mutex]. Call [record_attempt]
    for every gate ingress, including validation failures,
    then read state via [snapshot_json].

    @since 2.218.0 *)

(** Ingress outcome classification for connector diagnostics. *)
type outcome =
  | Success
  | Validation_error of string
  | Keeper_error of string
  | Dispatch_unavailable
  | Internal_error of string

val outcome_to_string : outcome -> string
(** The status-surface label: [success], [validation_error], [keeper_error],
    [dispatch_unavailable] or [internal_error]. *)

(** The kind of a failed attempt. A successful attempt has no failure, so
    there is no kind for it; the status JSON writes [""] in that place. *)
type error_kind =
  | Ek_validation
  | Ek_keeper
  | Ek_dispatch_unavailable
  | Ek_internal

val error_kind_of_string : string -> error_kind option
(** Parse one of the four labels {!error_kind_to_string} writes. Anything
    else is [None], including [""]: the status JSON writes [""] when there is
    no failure, and that is not a kind. *)

val error_kind_to_string : error_kind -> string
(** The JSON/status label: [validation], [keeper], [dispatch_unavailable]
    or [internal]. *)

(** What a failed attempt carries. *)
type failure = {
  kind : error_kind;
  message : string;
}

(** Per-channel statistics snapshot (immutable). *)
type channel_stats = {
  channel : string;
  message_count : int;
  success_count : int;
  error_count : int;
  validation_error_count : int;
  keeper_error_count : int;
  dispatch_unavailable_count : int;
  internal_error_count : int;
  last_activity_ts : float;
  last_success_ts : float;
  last_error_ts : float;
  last_keeper : string;
  last_workspace_id : string;
  last_error : failure option;
      (** The latest failure, kept after later successful attempts.
          [None] until an attempt fails. *)
  last_outcome : outcome;
      (** The latest attempt. Only its label reaches the status JSON; a
          failure's message goes out through [last_error]. *)
  total_duration_ms : int;
  timed_count : int;
  max_duration_ms : int;
  slow_count : int;
  workspace_count : int;
}

(** Per-workspace binding snapshot (channel workspace -> keeper). *)
type binding_stats = {
  channel : string;
  workspace_id : string;
  keeper : string;
  message_count : int;
  success_count : int;
  error_count : int;
  last_activity_ts : float;
  last_success_ts : float;
  last_error_ts : float;
  last_error : failure option;
      (** The latest failure, kept after later successful attempts.
          [None] until an attempt fails. *)
  last_outcome : outcome;
      (** The latest attempt. Only its label reaches the status JSON; a
          failure's message goes out through [last_error]. *)
  total_duration_ms : int;
  timed_count : int;
  max_duration_ms : int;
}

(** Recent connector event snapshot. The JSON [outcome], [error_kind] and
    [error] are all read off [outcome]. *)
type gate_event = {
  seq : int;
  timestamp : float;
  channel : string;
  workspace_id : string;
  keeper : string;
  outcome : outcome;
  duration_ms : int;
}

val max_recent_events : int
(** Maximum number of recent connector events retained in memory. *)

val record_attempt :
  channel:string ->
  workspace_id:string ->
  keeper:string ->
  duration_ms:int ->
  outcome ->
  unit
(** Record one gate attempt. Thread-safe.
    Channel names are normalized to lowercase in the stored observability
    surface so filtering is case-insensitive across connectors. *)

val record_internal_error_exn :
  channel:string ->
  workspace_id:string ->
  keeper:string ->
  duration_ms:int ->
  exn ->
  unit
(** Record an unexpected gate exception with the same channel metadata.
    The public status surface receives a redacted internal error string. *)

val snapshot : unit -> channel_stats list
(** Return a list of per-channel stats, sorted by message_count desc. *)

val snapshot_json : unit -> Yojson.Safe.t
(** Full status JSON for the [/api/v1/gate/status] endpoint. *)

val events_json :
  ?channel:string ->
  ?keeper:string ->
  ?workspace_id:string ->
  limit:int ->
  unit ->
  Yojson.Safe.t
(** Filtered recent-event JSON for the [/api/v1/gate/events] endpoint. *)
