(** Runtime-MCP policy header helpers, extracted from [Runtime_transport]. *)

(** Trim an optional string and return [None] for blank values. *)

val runtime_mcp_policy_with_masc_agent_name :
  agent_name:string ->
  Llm_provider.Llm_transport.runtime_mcp_policy ->
  Llm_provider.Llm_transport.runtime_mcp_policy
(** Inject non-secret MASC identity headers into the [masc] HTTP server entry.
    Authentication remains the policy builder's exact bearer capability. *)

val runtime_mcp_policy_without_http_headers :
  Llm_provider.Llm_transport.runtime_mcp_policy ->
  Llm_provider.Llm_transport.runtime_mcp_policy
(** Strip all HTTP headers from runtime MCP server entries. *)
