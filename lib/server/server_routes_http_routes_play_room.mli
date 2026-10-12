(** Authenticated public game conversation. This surface exposes only room
    messages, never Keeper transcripts or workspace broadcasts. *)
val path : string
val response : viewer:string -> (Play_room.snapshot, Play_room.error) result -> Httpun.Status.t * Yojson.Safe.t
val read : base_path:string -> Httpun.Request.t -> (Play_room.snapshot, Play_room.error) result
val perform : base_path:string -> who:string -> string -> (Play_room.snapshot, Play_room.error) result
(** Shared HTTP/1 and HTTP/2 handlers, called only after token permission checks. *)
val perform_bound : config:Workspace.config -> who:string -> string -> Httpun.Status.t * Yojson.Safe.t
(** Validate the captured workspace before any presence/message effect. Both
    HTTP transports use this boundary; unbound browser clients remain valid. *)
val add_routes : Http_server_eio.Router.t -> Http_server_eio.Router.t
