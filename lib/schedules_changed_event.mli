(** The push that says a workspace's schedules changed: the schedule store
    took a write, the schedule runner recorded a tick's outcome, or the
    runner's status passed its staleness deadline. It carries no payload: a
    reader that shows schedules re-fetches them on it. The server broadcasts
    it and the terminal client recognises it, so both read the name from
    here. *)

val event_type : string
(** The [type] field the frame carries. *)

val to_json : unit -> Yojson.Safe.t
(** The whole frame. *)
