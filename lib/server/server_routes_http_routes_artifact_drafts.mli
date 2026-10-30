val error_response : Artifact_draft_store.error -> Yojson.Safe.t * Httpun.Status.t
val decode_request : config:Workspace.config -> body:string ->
  (Artifact_draft.command, Yojson.Safe.t * Httpun.Status.t) result
val read : base_path:string -> artifact_id:string -> Yojson.Safe.t * Httpun.Status.t
val execute : config:Workspace.config -> actor:string -> body:string -> Yojson.Safe.t * Httpun.Status.t
val checkpoint : config:Workspace.config -> actor:string -> body:string -> Yojson.Safe.t * Httpun.Status.t
(** Callers must apply the same authentication and workspace admission on both transports. *)
val add_routes : Http_server_eio.Router.t -> Http_server_eio.Router.t
