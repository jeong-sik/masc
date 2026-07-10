(** Authorization header helpers for runtime MCP transport. *)

val upsert_http_header :
  key:string -> value:string -> (string * string) list -> (string * string) list

val keeper_name_of_agent_name : string -> string option

val per_keeper_authorization_header :
  base_path:string ->
  agent_name:string ->
  (string * string, Auth_resolve.auth_error) result
(** Resolve and verify the exact per-agent credential through
    {!Auth_resolve.resolve_runtime_mcp}. Missing, corrupt, expired, or
    owner-mismatched material is returned as a typed error and traced without
    exposing the secret. *)

val runtime_mcp_policy_uses_bound_actor_tools :
  Llm_provider.Llm_transport.runtime_mcp_policy -> bool

val add_masc_authorization_header :
  string * string ->
  Llm_provider.Llm_transport.runtime_mcp_policy ->
  Llm_provider.Llm_transport.runtime_mcp_policy
