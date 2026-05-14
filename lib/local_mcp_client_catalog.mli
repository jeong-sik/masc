(** Local MCP client catalog.

    Host MCP client identities are declared in
    [cascade.toml] under [providers.<id>.mcp_client_config]. Runtime
    auth/bootstrap code should query this catalog instead of branching on
    client names inline. *)

type config_sync = {
  enabled_env_var : string;
  config_path_env_var : string;
  default_config_path_segments : string list;
}

type spawn_tool_surface =
  | Spawned_agent_tools
  | No_spawn_tools

type spawn_mcp_mode =
  | Spawn_mcp_joined of string
  | Spawn_mcp_spread of {
      server_name : string;
      flag : string;
    }
  | Spawn_mcp_none

type spawn_prompt_mode =
  | Spawn_prompt_flag of string
  | Spawn_prompt_stdin

type spawn_output_parser =
  | Spawn_parse_raw
  | Spawn_parse_result_usage_json
  | Spawn_parse_response_usage_json

type spawn = {
  agent_name : string;
  aliases : string list;
  command : string;
  timeout_seconds : int option;
  working_dir : string option;
  tool_surface : spawn_tool_surface;
  output_parser : spawn_output_parser;
  stdin_prompt : bool;
  mcp_mode : spawn_mcp_mode;
  prompt_mode : spawn_prompt_mode;
}

type spec = {
  provider_id : string;
  client_name : string;
  agent_name : string;
  token_env_var : string;
  server_name : string;
  login_supported : bool;
  login_note : string option;
  legacy_agent_names : string list;
  config_sync : config_sync option;
  spawn : spawn option;
}

val all : unit -> spec list
val default_server_name : string
val default_token_env_var : string
val token_env_var_for_agent : string -> string
val registered_agent : string -> bool
val agent_names : unit -> string list
val find_by_agent_name : string -> spec option
val config_sync_for_agent : string -> (spec * config_sync) option
val primary_config_sync_client : unit -> spec * config_sync
val find_spawn : string -> (spec * spawn) option
val audited_spawn_executables : unit -> string list
