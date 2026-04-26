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

(** Per-channel statistics snapshot (immutable). *)
type channel_stats =
  { channel : string
  ; message_count : int
  ; success_count : int
  ; error_count : int
  ; duplicate_count : int
  ; validation_error_count : int
  ; keeper_error_count : int
  ; dispatch_unavailable_count : int
  ; internal_error_count : int
  ; last_activity_ts : float
  ; last_success_ts : float
  ; last_error_ts : float
  ; last_keeper : string
  ; last_room_id : string
  ; last_error : string
  ; last_error_kind : string
  ; last_outcome : string
  ; total_duration_ms : int
  ; timed_count : int
  ; max_duration_ms : int
  ; slow_count : int
  ; room_count : int
  }

(** Per-room binding snapshot (channel room -> keeper). *)
type binding_stats =
  { channel : string
  ; room_id : string
  ; keeper : string
  ; message_count : int
  ; success_count : int
  ; error_count : int
  ; duplicate_count : int
  ; last_activity_ts : float
  ; last_success_ts : float
  ; last_error_ts : float
  ; last_error : string
  ; last_error_kind : string
  ; last_outcome : string
  ; total_duration_ms : int
  ; timed_count : int
  ; max_duration_ms : int
  }

(** Recent connector event snapshot. *)
type gate_event =
  { seq : int
  ; timestamp : float
  ; channel : string
  ; room_id : string
  ; keeper : string
  ; outcome : string
  ; error_kind : string
  ; error : string
  ; duration_ms : int
  }

(** Maximum number of recent connector events retained in memory. *)
val max_recent_events : int

(** Record one gate attempt. Thread-safe.
    Channel names are normalized to lowercase in the stored observability
    surface so filtering is case-insensitive across connectors. *)
val record_attempt
  :  channel:string
  -> room_id:string
  -> keeper:string
  -> duration_ms:int
  -> outcome
  -> unit

(** Record an unexpected gate exception with the same channel metadata.
    The public status surface receives a redacted internal error string. *)
val record_internal_error_exn
  :  channel:string
  -> room_id:string
  -> keeper:string
  -> duration_ms:int
  -> exn
  -> unit

(** Return a list of per-channel stats, sorted by message_count desc. *)
val snapshot : unit -> channel_stats list

(** Full status JSON for the [/api/v1/gate/status] endpoint. *)
val snapshot_json : unit -> Yojson.Safe.t

(** Filtered recent-event JSON for the [/api/v1/gate/events] endpoint. *)
val events_json
  :  ?channel:string
  -> ?keeper:string
  -> ?room_id:string
  -> limit:int
  -> unit
  -> Yojson.Safe.t

(** Sum of all channels' message counts. *)
val total_messages : unit -> int

(** Current dedup hashtable occupancy. *)
val dedup_table_size : unit -> int

(** Register the dedup table size callback.  Called by [Channel_gate]
    at module init to break the dependency cycle. *)
val register_dedup_size_fn : (unit -> int) -> unit
