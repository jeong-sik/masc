(** Per-keeper authorization bridging for runtime MCP policies. *)

val cli_tool_a_can_auth_keeper_bound_runtime_mcp :
  agent_name:string ->
  Llm_provider.Llm_transport.runtime_mcp_policy ->
  bool
(** [true] when the cli_tool_a transport can mint a per-keeper
    Authorization header for actor-bound runtime MCP tools. *)

val bridged_runtime_mcp_policy_for_agent :
  agent_name:string ->
  Llm_provider.Llm_transport.runtime_mcp_policy ->
  Llm_provider.Llm_transport.runtime_mcp_policy
(** Strip inbound HTTP headers, re-inject MASC identity headers, and attach the
    selected Authorization header when available. *)
