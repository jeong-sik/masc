(** Local MCP client catalog.

    This is the single repo-local place for host MCP client identities that
    need bearer-token files or client-specific environment variables. Runtime
    auth/bootstrap code should query this catalog instead of branching on
    client names inline. *)

type config_sync = {
  enabled_env_var : string;
  config_path_env_var : string;
  default_config_path_segments : string list;
}

type spec = {
  client_name : string;
  agent_name : string;
  token_env_var : string;
  server_name : string;
  login_supported : bool;
  login_note : string option;
  legacy_agent_names : string list;
  config_sync : config_sync option;
}

val all : spec list
val default_server_name : string
val default_token_env_var : string
val token_env_var_for_agent : string -> string
val registered_agent : string -> bool
val agent_names : unit -> string list
val find_by_agent_name : string -> spec option
val config_sync_for_agent : string -> (spec * config_sync) option
val primary_config_sync_client : unit -> spec * config_sync
