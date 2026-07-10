(** Per-keeper authorization bridging for runtime MCP policies. *)

val codex_cli_can_auth_keeper_bound_runtime_mcp :
  base_path:string ->
  agent_name:string ->
  Llm_provider.Llm_transport.runtime_mcp_policy ->
  (bool, Auth_resolve.auth_error) result
(** [Ok true] when the transport can mint a verified per-keeper Authorization
    header for actor-bound runtime MCP tools; credential failures remain typed. *)

val bridged_runtime_mcp_policy_for_agent :
  base_path:string ->
  agent_name:string ->
  Llm_provider.Llm_transport.runtime_mcp_policy ->
  ( Llm_provider.Llm_transport.runtime_mcp_policy,
    Auth_resolve.auth_error )
  result
(** Strip inbound HTTP headers, re-inject MASC identity headers, and attach a
    freshly verified per-agent Authorization header. Missing or invalid
    credentials return [Error]; no headerless policy is emitted. *)
