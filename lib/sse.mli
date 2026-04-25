(** Sse — Server-Sent Events hub for MASC.

    Manages SSE client sessions, event broadcasting, and external subscribers.
    Uses Atomic.t for lock-free session state and Eio.Stream for event delivery.

    @since 0.1.0 *)

(** {1 Types} *)

module SMap : Map.S with type key = string

type session_kind =
  | Observer
  | Coordinator

type broadcast_target =
  | All
  | Observers
  | Coordinators

type client = {
  id : int;
  kind : session_kind;
  event_stream : string Eio.Stream.t;
  last_event_id : int Atomic.t;
  created_at : float;
  last_seen_at : float Atomic.t;
}

type client_registry_state = {
  entries : client SMap.t;
  count : int;
}

type session_snapshot = {
  session_id : string;
  kind : session_kind;
  queue_depth : int;
  last_event_id : int;
  idle_seconds : float;
}

(** {1 Constants} *)

val max_clients : int
val max_buffer_size : int
val buffer_ttl_seconds : float

(** {1 Session Management} *)

val register :
  ?kind:session_kind -> string -> last_event_id:int ->
  int * string Eio.Stream.t * string option
val unregister : string -> unit
val unregister_if_current : string -> int -> unit
val exists : string -> bool
val touch : string -> unit
val update_last_event_id : string -> int -> unit
val all_session_ids : unit -> string list
val client_count : unit -> int
val close_all_clients : unit -> int
val cleanup_stale : ?max_age_s:float -> unit -> string list

(** {1 Clock} *)

val set_clock : float Eio.Time.clock_ty Eio.Resource.t -> unit

(** {1 Events} *)

val format_event : ?id:int -> ?event_type:string -> string -> string
val next_id : unit -> int
val current_id : unit -> int

(** {1 Broadcast} *)

val broadcast : Yojson.Safe.t -> unit
val broadcast_to : broadcast_target -> Yojson.Safe.t -> unit
val send_to : string -> Yojson.Safe.t -> unit
val pop : string -> string option
val try_pop : string -> string option

(** {1 External Subscribers} *)

val subscribe_external :
  id:string -> callback:(string -> unit) -> ?is_alive:(unit -> bool) -> unit -> unit
val unsubscribe_external : string -> unit
val external_subscriber_count : unit -> int
val external_subscriber_count_with_prefix : string -> int
val reap_dead_external_subscribers : unit -> int
val remove_external_subscribers : string list -> string list * int

(** {1 Event Buffer} *)

val clients : client_registry_state Atomic.t
val event_buffer : (int * string * float) list Atomic.t
val buffer_event : int -> string -> unit
val get_events_after : int -> string list
val cleanup_expired_events : unit -> int

(** {1 Snapshots} *)

val sync_transport_snapshot : unit -> unit
val session_kind_to_string : session_kind -> string

(** {1 Test Hooks} *)

val register_commit_test_hook : (unit -> unit) option Atomic.t
val buffer_commit_test_hook : (unit -> unit) option Atomic.t
