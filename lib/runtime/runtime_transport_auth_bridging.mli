(** Per-keeper authorization bridging for runtime MCP policies. *)

val codex_cli_can_auth_keeper_bound_runtime_mcp :
  base_path:string ->
  agent_name:string ->
  Llm_provider.Llm_transport.runtime_mcp_policy ->
  bool
(** [true] when the codex_cli transport can mint a per-keeper
    Authorization header for actor-bound runtime MCP tools. *)

val bridged_runtime_mcp_policy_for_agent :
  base_path:string ->
  agent_name:string ->
  Llm_provider.Llm_transport.runtime_mcp_policy ->
  Llm_provider.Llm_transport.runtime_mcp_policy
(** Strip inbound HTTP headers, re-inject MASC identity headers, and attach the
    selected Authorization header when available. *)
