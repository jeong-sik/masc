(** Runtime-MCP policy builder for tool-name lists. *)

val runtime_mcp_policy_of_tool_names :
  base_path:string ->
  ?agent_name:string ->
  string list ->
  Llm_provider.Llm_transport.runtime_mcp_policy option
(** Build a strict [masc] runtime MCP policy for the exact non-empty schema
    names supplied by the caller. No static tool catalog reclassifies them. *)
