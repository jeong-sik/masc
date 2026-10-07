(** Authenticated public game conversation. This surface exposes only room
    messages, never Keeper transcripts or workspace broadcasts. *)
val path : string
val response : viewer:string -> (Play_room.snapshot, Play_room.error) result -> Httpun.Status.t * Yojson.Safe.t
val add_routes : Http_server_eio.Router.t -> Http_server_eio.Router.t
