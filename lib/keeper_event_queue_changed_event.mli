(** The push that says one Keeper's event queue, or the reaction record kept
    beside it, changed. A reader that shows queue or reaction evidence for
    that Keeper -- the schedule rows do -- re-fetches it. The server
    broadcasts it and the terminal client recognises it, so both read the
    name from here. *)

val event_type : string
(** The [type] field the frame carries. *)

val to_json : keeper_name:string -> Yojson.Safe.t
(** The whole frame; [keeper] names the Keeper whose queue changed. *)
