val error_response : Published_artifact_store.error -> Yojson.Safe.t * Httpun.Status.t
val check_error_response : Published_artifact_check_store.error -> Yojson.Safe.t * Httpun.Status.t
val decode_check_request : config:Workspace.config -> body:string ->
  (Published_artifact_check.request, Yojson.Safe.t * Httpun.Status.t) result
(** Validate and strip an optional expected workspace before strict operation
    decoding. Refusal precedes store dispatch; the handler uses this config. *)
type response = { status : Httpun.Status.t; json : Yojson.Safe.t }
type read_result = Private | Response of response

val list : base_path:string -> response
val read : base_path:string -> actor:string option -> request:Httpun.Request.t -> read_result
val publish : base_path:string -> actor:string -> body:string -> response
val list_checks : base_path:string -> response
val set_check : config:Workspace.config -> actor:string -> body:string -> response
val set_share : config:Workspace.config -> body:string -> response
(** Shared transport-independent operations. Callers must apply the same
    authorization and rate limits as the HTTP/1 routes before invoking these.
    [Private] means an anonymous single-artifact read requires authentication;
    the transport owns its authentication response. Store I/O runs in a
    systhread. These responses contain status and JSON only; transports set
    private no-store and their own CORS headers. *)
val add_routes : Http_server_eio.Router.t -> Http_server_eio.Router.t
