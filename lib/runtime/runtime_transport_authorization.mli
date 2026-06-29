(** Authorization header helpers for runtime runtime MCP transport. *)

val upsert_http_header :
  key:string -> value:string -> (string * string) list -> (string * string) list

val keeper_name_of_agent_name : string -> string option
val is_authorization_header : string * string -> bool

val authorization_header_from_policy :
  Llm_provider.Llm_transport.runtime_mcp_policy -> (string * string) option

val per_keeper_authorization_header :
  base_path:string -> agent_name:string -> (string * string) option

val runtime_mcp_policy_uses_bound_actor_tools :
  Llm_provider.Llm_transport.runtime_mcp_policy -> bool

val add_masc_authorization_header :
  string * string ->
  Llm_provider.Llm_transport.runtime_mcp_policy ->
  Llm_provider.Llm_transport.runtime_mcp_policy
