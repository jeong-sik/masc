(** Provider-driven runtime MCP policy resolver + CLI JSON merger. *)

val runtime_mcp_policy_for_provider :
     provider_cfg:Llm_provider.Provider_config.t
  -> agent_name:string
  -> Llm_provider.Llm_transport.runtime_mcp_policy option
  -> Llm_provider.Llm_transport.runtime_mcp_policy option

val cli_runtime_mcp_jsons :
  base:string list ->
  Llm_provider.Llm_transport.runtime_mcp_policy option ->
  string list
