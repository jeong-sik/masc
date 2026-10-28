val error_response : Artifact_draft_store.error -> Yojson.Safe.t * Httpun.Status.t
val decode_request : config:Workspace.config -> body:string ->
  (Artifact_draft.command, Yojson.Safe.t * Httpun.Status.t) result
val add_routes : Http_server_eio.Router.t -> Http_server_eio.Router.t
