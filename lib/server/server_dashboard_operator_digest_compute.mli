val observe_current :
  state:Mcp_server.server_state -> scope:Mcp_server.workspace_scope ->
  sw:Eio.Switch.t -> clock:float Eio.Time.clock_ty Eio.Resource.t ->
  query:Yojson.Safe.t -> ?actor:string -> ?target_type:string ->
  ?target_id:string -> ?include_workers:bool -> unit ->
  (Dashboard_projection_cache.digest_observation, string) result
(** One actual digest read in the captured scope, bypassing projection TTLs.
    Query/provenance metadata and the original observation's semantic deadline
    come from the same computation. No lane action/provider call is admitted. *)
