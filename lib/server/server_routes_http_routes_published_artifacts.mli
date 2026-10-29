val error_response : Published_artifact_store.error -> Yojson.Safe.t * Httpun.Status.t
val check_error_response : Published_artifact_check_store.error -> Yojson.Safe.t * Httpun.Status.t
val validate_body_workspace : config:Workspace.config -> Yojson.Safe.t ->
  (Yojson.Safe.t, Yojson.Safe.t * Httpun.Status.t) result
val decode_publication_request : config:Workspace.config -> body:string ->
  (Published_artifact.request, Yojson.Safe.t * Httpun.Status.t) result
val decode_check_request : config:Workspace.config -> body:string ->
  (Published_artifact_check.request, Yojson.Safe.t * Httpun.Status.t) result
val decode_share_request : config:Workspace.config -> body:string ->
  ((string * Published_artifact_share.request), Yojson.Safe.t * Httpun.Status.t) result
(** Share changes require a workspace identity, an observed version and an
    operation identity so that an uncertain request can be replayed exactly. *)
type response = { status : Httpun.Status.t; json : Yojson.Safe.t }
type read_result = Private | Response of response

val list : base_path:string -> response
val read : base_path:string -> actor:string option -> request:Httpun.Request.t -> read_result
val publish : config:Workspace.config -> actor:string -> body:string -> response
val list_checks : base_path:string -> response
val set_check : config:Workspace.config -> actor:string -> body:string -> response
val set_share : config:Workspace.config -> body:string -> response
(** Shared transport-independent operations. Callers apply the same
    authorization and rate limits as the HTTP/1 routes before invoking these. *)
val add_routes : Http_server_eio.Router.t -> Http_server_eio.Router.t
