(** A workspace skill catalog snapshot was published. It carries no snapshot: a
    reader that shows skills ([GET /api/v1/skills], the Keeper surface in
    [GET /api/v1/dashboard/tools]) reads it again. *)

val event_type : string

val json : ts_unix:float -> Yojson.Safe.t
