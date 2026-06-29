(** Provider-driven runtime MCP policy resolver. *)

val runtime_mcp_policy_for_provider :
  base_path:string ->
  provider_cfg:Llm_provider.Provider_config.t ->
  agent_name:string ->
  Llm_provider.Llm_transport.runtime_mcp_policy option ->
  Llm_provider.Llm_transport.runtime_mcp_policy option
(** Shape a runtime MCP policy according to provider tool-delivery capability. *)
