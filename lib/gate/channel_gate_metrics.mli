(** Channel_gate_metrics -- connector diagnostics, outcomes, latency, and status.

    Thread-safe via [Eio_guard.with_mutex]. Call [record_attempt]
    for every gate ingress, including validation failures and duplicates,
    then read state via [snapshot_json].

    @since 2.218.0 *)

(** Ingress outcome classification for connector diagnostics. *)
type outcome =
  | Success
  | Duplicate
  | Validation_error of string
  | Keeper_error of string
  | Dispatch_unavailable
  | Internal_error of string

(** Connector error-kind labels. Closed set mirroring the in-module
    producer surface: validation / keeper / dispatch_unavailable /
    internal, plus [Ek_none] as the sentinel used by [Success] and
    [Duplicate] outcomes (previously the empty-string [Error_kind ""]).

    JSON/status surfaces render via [error_kind_to_string]; wire output
    is byte-compatible with the prior [private Error_kind of string]
    wrapper. *)
type error_kind =
  | Ek_none
  | Ek_validation
  | Ek_keeper
  | Ek_dispatch_unavailable
  | Ek_internal

val error_kind_of_string : string -> error_kind option
(** Parse a wire label. [None] on unknown so JSON read paths fail
    closed (CLAUDE.md anti-pattern #2 — Unknown → Permissive Default
    forbidden). *)

val error_kind_to_string : error_kind -> string
(** Render to the JSON/status wire label (byte-compatible with the
    pre-typing private-string wrapper). *)

(** Per-channel statistics snapshot (immutable). *)
type channel_stats = {
  channel : string;
  message_count : int;
  success_count : int;
  error_count : int;
  duplicate_count : int;
  validation_error_count : int;
  keeper_error_count : int;
  dispatch_unavailable_count : int;
  internal_error_count : int;
  last_activity_ts : float;
  last_success_ts : float;
  last_error_ts : float;
  last_keeper : string;
  last_room_id : string;
  last_error : string;
  last_error_kind : error_kind;
  last_outcome : string;
  total_duration_ms : int;
  timed_count : int;
  max_duration_ms : int;
  slow_count : int;
  room_count : int;
}

(** Per-room binding snapshot (channel room -> keeper). *)
type binding_stats = {
  channel : string;
  room_id : string;
  keeper : string;
  message_count : int;
  success_count : int;
  error_count : int;
  duplicate_count : int;
  last_activity_ts : float;
  last_success_ts : float;
  last_error_ts : float;
  last_error : string;
  last_error_kind : error_kind;
  last_outcome : string;
  total_duration_ms : int;
  timed_count : int;
  max_duration_ms : int;
}

(** Recent connector event snapshot. *)
type gate_event = {
  seq : int;
  timestamp : float;
  channel : string;
  room_id : string;
  keeper : string;
  outcome : string;
  error_kind : error_kind;
  error : string;
  duration_ms : int;
}

val max_recent_events : int
(** Maximum number of recent connector events retained in memory. *)

val record_attempt :
  channel:string ->
  room_id:string ->
  keeper:string ->
  duration_ms:int ->
  outcome ->
  unit
(** Record one gate attempt. Thread-safe.
    Channel names are normalized to lowercase in the stored observability
    surface so filtering is case-insensitive across connectors. *)

val record_internal_error_exn :
  channel:string ->
  room_id:string ->
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
  ?room_id:string ->
  limit:int ->
  unit ->
  Yojson.Safe.t
(** Filtered recent-event JSON for the [/api/v1/gate/events] endpoint. *)

val total_messages : unit -> int
(** Sum of all channels' message counts. *)

val dedup_table_size : unit -> int
(** Current dedup hashtable occupancy. *)

val register_dedup_size_fn : (unit -> int) -> unit
(** Register the dedup table size callback.  Called by [Channel_gate]
    at module init to break the dependency cycle. *)
