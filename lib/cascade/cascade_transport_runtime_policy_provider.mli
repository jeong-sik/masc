(** Provider-driven runtime MCP policy resolver and CLI JSON merger. *)

val runtime_mcp_policy_for_provider :
  provider_cfg:Llm_provider.Provider_config.t ->
  agent_name:string ->
  Llm_provider.Llm_transport.runtime_mcp_policy option ->
  Llm_provider.Llm_transport.runtime_mcp_policy option
(** Shape a runtime MCP policy according to provider tool-delivery capability. *)

val cli_runtime_mcp_jsons :
  base:string list ->
  Llm_provider.Llm_transport.runtime_mcp_policy option ->
  string list
(** Merge base CLI MCP JSON entries with a runtime-policy projection. *)
