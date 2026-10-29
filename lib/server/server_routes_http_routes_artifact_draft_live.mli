val target_of_request : Httpun.Request.t -> (Artifact_draft.target, string) result
val join : base_path:string -> actor:string -> target:Artifact_draft.target ->
  (Artifact_draft_live.session, Artifact_draft_store.error) result
(** Registers before reading the draft, and releases the session if reading or
    target validation fails. A successful caller owns the session lifetime. *)
val presence : config:Workspace.config -> actor:string -> body:string -> Yojson.Safe.t * Httpun.Status.t
(** Apply an authenticated connection-owned presence command. *)
val add_routes : Http_server_eio.Router.t -> Http_server_eio.Router.t
