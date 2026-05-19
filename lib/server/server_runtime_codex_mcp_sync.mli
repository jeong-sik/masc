(** Codex MCP config and raw client token bootstrap sync helpers. *)

val sync_codex_mcp_config_env_key : string
val codex_config_path_env_key : string

type codex_mcp_config_sync_status =
  | Codex_mcp_config_updated
  | Codex_mcp_config_unchanged
  | Codex_mcp_config_server_missing
  | Codex_mcp_config_header_missing

val sync_codex_mcp_auth_header_content :
  string -> string * codex_mcp_config_sync_status

val sync_codex_mcp_config : agent_name:string -> unit
val sync_mcp_client_token_files : base_path:string -> unit
