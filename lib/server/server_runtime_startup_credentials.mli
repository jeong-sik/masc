val sync_admin_token_env :
  Mcp_server.server_state -> (unit, Masc_domain.masc_error) result
(** Prepare and export the startup Admin bearer. Auth owns typed owner and pair
    admission. A failed read, verification or publication returns [Error] so the
    owner bootstrap refuses before readiness. Successful reuse does not rewrite
    the persisted pair. Cancellation propagates. *)
val sync_internal_keeper_token_env : Mcp_server.server_state -> unit
val sync_bootable_keeper_credentials :
  Mcp_server.server_state -> unit
