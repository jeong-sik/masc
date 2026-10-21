val error_response : Published_artifact_store.error -> Yojson.Safe.t * Httpun.Status.t
val check_error_response : Published_artifact_check_store.error -> Yojson.Safe.t * Httpun.Status.t
val decode_check_request : config:Workspace.config -> body:string ->
  (Published_artifact_check.request, Yojson.Safe.t * Httpun.Status.t) result
(** Validate and strip an optional expected workspace before strict operation
    decoding. Refusal precedes store dispatch; the handler uses this config. *)
val add_routes : Http_server_eio.Router.t -> Http_server_eio.Router.t
