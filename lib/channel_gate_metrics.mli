(** Channel_gate_metrics -- per-channel message counters and status.

    Thread-safe via [Eio_guard.with_mutex].  Call [record_message]
    after each gate dispatch; read state via [snapshot_json].

    @since 2.218.0 *)

(** Per-channel statistics snapshot (immutable). *)
type channel_stats = {
  channel : string;
  message_count : int;
  error_count : int;
  last_activity_ts : float;
  last_keeper : string;
  total_duration_ms : int;
}

val record_message :
  channel:string -> keeper:string -> duration_ms:int -> success:bool -> unit
(** Record one gate message.  Thread-safe. *)

val snapshot : unit -> channel_stats list
(** Return a list of per-channel stats, sorted by message_count desc. *)

val snapshot_json : unit -> Yojson.Safe.t
(** Full status JSON for the [/api/v1/gate/status] endpoint. *)

val total_messages : unit -> int
(** Sum of all channels' message counts. *)

val dedup_table_size : unit -> int
(** Current dedup hashtable occupancy. *)

val register_dedup_size_fn : (unit -> int) -> unit
(** Register the dedup table size callback.  Called by [Channel_gate]
    at module init to break the dependency cycle. *)
