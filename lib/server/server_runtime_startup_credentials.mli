val keeper_egress_inactive_missing_reason :
  metas:Keeper_types.keeper_meta list ->
  Keeper_egress_audit.result -> string option
val audit_keeper_egress_policies : Mcp_server.server_state -> unit
val sync_admin_token_env : Mcp_server.server_state -> unit
val sync_internal_keeper_token_env : Mcp_server.server_state -> unit
val sync_bootable_keeper_credentials :
  Mcp_server.server_state -> unit
