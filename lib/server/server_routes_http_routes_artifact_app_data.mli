val decode_request :
  config:Workspace.config -> string ->
  (Artifact_app_data.request, Yojson.Safe.t * Httpun.Status.t) result
val read :
  base_path:string -> actor:string -> request:Httpun.Request.t ->
  Yojson.Safe.t * Httpun.Status.t
val set :
  config:Workspace.config -> actor:string -> body:string ->
  Yojson.Safe.t * Httpun.Status.t
(** Transport-independent operations. Authentication and workspace admission
    must happen before invoking them. *)
val add_routes : Http_server_eio.Router.t -> Http_server_eio.Router.t
