val error_response : Artifact_draft_store.error -> Yojson.Safe.t * Httpun.Status.t
val add_routes : Http_server_eio.Router.t -> Http_server_eio.Router.t
