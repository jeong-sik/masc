(** SSE room-based event filtering

    Tracks session-to-room mappings so SSE broadcasts can be scoped
    to room members only.  Prevents agents in room-1 from receiving
    events from room-2.

    This module maintains its own mapping table; the actual SSE send
    is delegated to a callback so there is no dependency on the
    transport layer.

    @since 2.95.0
*)

(** [register ~session_id ~room_id] associates a session with a room.
    A session can be in at most one room (last registration wins). *)
val register : session_id:string -> room_id:string -> unit

(** [unregister ~session_id] removes the session from room tracking. *)
val unregister : session_id:string -> unit

(** [room_of ~session_id] returns the room this session belongs to. *)
val room_of : session_id:string -> string option

(** [sessions_in_room ~room_id] returns all session IDs in a room. *)
val sessions_in_room : room_id:string -> string list

(** [should_receive ~session_id ~event_room_id] returns true if the
    session should receive an event from [event_room_id].

    Rules:
    - If the session has no room (unregistered), it receives nothing.
    - If the event has no room (global), everyone receives it.
    - Otherwise, only matching rooms. *)
val should_receive : session_id:string -> event_room_id:string option -> bool

(** [broadcast_to_room ~room_id ~send_fn payload] sends [payload] to
    all sessions in [room_id] via [send_fn session_id payload].

    @param send_fn Callback that sends to a single session. *)
val broadcast_to_room
  :  room_id:string
  -> send_fn:(string -> Yojson.Safe.t -> unit)
  -> Yojson.Safe.t
  -> unit

(** [clear ()] removes all registrations (for testing). *)
val clear : unit -> unit

(** [registered_count ()] returns the number of tracked sessions. *)
val registered_count : unit -> int
