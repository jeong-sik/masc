(** Runtime-MCP policy builder for tool-name lists. *)

val runtime_mcp_policy_of_tool_names :
  base_path:string ->
  ?agent_name:string ->
  ?allow_agent_internal:bool ->
  string list ->
  Llm_provider.Llm_transport.runtime_mcp_policy option
(** Build a strict [masc] runtime MCP policy for eligible tool names. *)

val public_mcp_runtime_policy_of_tool_names :
  base_path:string ->
  ?agent_name:string ->
  string list ->
  Llm_provider.Llm_transport.runtime_mcp_policy option
(** Public-only variant of {!runtime_mcp_policy_of_tool_names}. *)
