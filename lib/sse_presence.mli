(** Sse_presence — Independent SSE channel for awareness/presence traffic.

    Implements the server-side half of RFC PR-1.7
    ([docs/rfc/awareness-channel-split.md]).  This module owns its own
    client registry and event buffer so that broadcasting heartbeat-class
    events on the presence channel does not flood the main MCP SSE
    stream, and vice versa.

    Wire compatibility: events are formatted via {!Sse.format_event} so
    on-the-wire framing is identical to the main channel.  The two
    channels diverge in [event_counter] (separate sequences for
    independent [Last-Event-Id] resumability) and in subscriber set
    (separate [Atomic.t] registries).

    Caller layering: this module is intentionally minimal — it is the
    storage + fan-out primitive.  HTTP route wiring (e.g. an
    [/events/presence] endpoint) and producer-side dual-emit live in
    follow-on PRs (PR-1.7a-1-β and PR-1.7a-2 respectively).

    @since 0.18.x *)

(** {1 Types} *)

module SMap : Map.S with type key = string

(** Per-session presence subscriber.

    Unlike {!Sse.client}, presence subscribers do not have a
    [session_kind] — every subscriber is treated equally. *)
type client = {
  id : int;
  event_stream : string Eio.Stream.t;
  last_event_id : int Atomic.t;
  created_at : float;
  last_seen_at : float Atomic.t;
}

type client_registry_state = {
  entries : client SMap.t;
  count : int;
}

(** {1 Constants} *)

val max_clients : int
val max_buffer_size : int
val buffer_ttl_seconds : float
val stream_capacity : int

(** {1 Session Management} *)

(** [register session_id ~last_event_id] registers a new presence
    subscriber. Returns [(client_id, event_stream, evicted_session_id_opt)].
    Same eviction semantics as {!Sse.register}: oldest client is evicted
    at capacity. *)
val register :
  string -> last_event_id:int ->
  int * string Eio.Stream.t * string option

val unregister : string -> unit
val unregister_if_current : string -> int -> unit
val exists : string -> bool
val touch : string -> unit
val update_last_event_id : string -> int -> unit
val all_session_ids : unit -> string list
val client_count : unit -> int
val close_all_clients : unit -> int

(** {1 Events} *)

(** Allocate next presence event id (independent of {!Sse.next_id}). *)
val next_id : unit -> int

val current_id : unit -> int

(** {1 Broadcast} *)

(** Push event to every registered presence subscriber. Wire-format is
    {!Sse.format_event} with [~event_type:"message"]. *)
val broadcast : Yojson.Safe.t -> unit

(** Pop the next queued event for a session. Blocks until one arrives.
    Returns [None] if the session has been unregistered. *)
val pop : string -> string option

(** Non-blocking pop — returns [None] when the queue is empty. *)
val try_pop : string -> string option

(** {1 Event Buffer} *)

val clients : client_registry_state Atomic.t
val event_buffer : (int * string * float) list Atomic.t
val buffer_event : int -> string -> unit
val get_events_after : int -> string list
val cleanup_expired_events : unit -> int
