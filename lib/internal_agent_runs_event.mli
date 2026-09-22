(** The push that says an internal agent run registry changed.

    The verification, goal-verification and exact-lane run registries each
    call it when a run is added or settles. It carries no payload: a reader
    that shows internal runs re-fetches them on it. The server broadcasts it
    and the terminal client recognises it, so both read the name from here. *)

val event_type : string
(** The [type] field the frame carries. *)

val to_json : unit -> Yojson.Safe.t
(** The whole frame. *)
