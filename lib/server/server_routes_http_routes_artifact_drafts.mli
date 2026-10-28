val error_response : Artifact_draft_store.error -> Yojson.Safe.t * Httpun.Status.t
val read : base_path:string -> artifact_id:string -> Yojson.Safe.t * Httpun.Status.t
val execute : base_path:string -> actor:string -> body:string -> Yojson.Safe.t * Httpun.Status.t
val checkpoint : base_path:string -> actor:string -> body:string -> Yojson.Safe.t * Httpun.Status.t
(** Transport-independent operations. Authentication and workspace admission
    precede these calls on both HTTP/1 and HTTP/2. *)
val add_routes : Http_server_eio.Router.t -> Http_server_eio.Router.t
