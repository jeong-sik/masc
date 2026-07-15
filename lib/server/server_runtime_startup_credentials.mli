val sync_internal_keeper_token_env : Mcp_server.server_state -> unit
val sync_bootable_keeper_credentials :
  Mcp_server.server_state -> unit

val sync_startup_credentials : Mcp_server.server_state -> unit
(** Synchronize the credentials owned by server startup: the internal keeper
    transport token and bootable keeper credentials. Operator/admin authority
    is deliberately outside this boundary. *)
