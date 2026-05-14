(** Local MCP client identity registry.

    This is the single code-level catalog for first-party local MCP clients
    that need stable bearer-token files and generated client config. *)

type spec =
  { client_name : string
  ; agent_name : string
  ; token_env_var : string
  }

val codex_server_name : string
val codex_client_name : string
val codex_agent_name : string
val codex_token_env_var : string
val codex_login_supported : bool
val codex_login_note : string
val gemini_agent_name : string

val dashboard_dev_agent_name : string
val admin_agent_name : string

val generated_config_server_name : string
val generated_config_client : spec
val generated_config_sync_env_key : string
val generated_config_path_env_key : string
val generated_config_relative_path : string
val generated_config_login_supported : bool
val generated_config_login_note : string

val specs : spec list
val token_env_var_for_agent : string -> string
val is_agent_name : string -> bool
val worker_agent_credentials : (string * Masc_domain.agent_role) list

val watched_agent_names :
  initial_admin:string option -> admin_token_env_agent:string option -> string list
