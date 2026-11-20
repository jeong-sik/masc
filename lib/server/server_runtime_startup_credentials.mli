val sync_admin_token_env :
  ?export_env:bool -> Mcp_server.server_state -> (unit, Masc_domain.masc_error) result
(** Prepare and optionally export the startup Admin bearer. Auth owns typed
    owner and pair admission. A failed read, verification or publication returns
    [Error] so the owner bootstrap refuses before readiness. Successful reuse
    does not rewrite the persisted pair. When [export_env] is [false] (used in
    multi-account mode), the token is not exported to the process environment.
    Cancellation propagates. *)
val sync_internal_keeper_token_env : ?export_env:bool -> Mcp_server.server_state -> unit
val sync_bootable_keeper_credentials :
  ?export_env:bool -> Mcp_server.server_state -> unit
