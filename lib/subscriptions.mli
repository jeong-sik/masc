(** Session push bridge: delivers a structured event to every active agent
    session's notification queue. *)

val set_session_push_fn : (Yojson.Safe.t -> int) -> unit
val push_event_to_sessions : Yojson.Safe.t -> unit
