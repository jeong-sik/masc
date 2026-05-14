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

let default_server_name = "masc"
let default_token_env_var = "MASC_MCP_TOKEN"

let all =
  [
    {
      client_name = "codex";
      agent_name = "codex-mcp-client";
      token_env_var = default_token_env_var;
      server_name = default_server_name;
      login_supported = false;
      login_note =
        Some
          "`codex mcp login` is OAuth-only; masc-mcp uses bearer token auth.";
      legacy_agent_names = [ "codex" ];
      config_sync =
        Some
          {
            enabled_env_var = "MASC_SYNC_CODEX_MCP_CONFIG";
            config_path_env_var = "MASC_CODEX_CONFIG_PATH";
            default_config_path_segments = [ ".codex"; "config.toml" ];
          };
    };
    {
      client_name = "claude";
      agent_name = "claude";
      token_env_var = "MASC_CLAUDE_MCP_TOKEN";
      server_name = default_server_name;
      login_supported = false;
      login_note = None;
      legacy_agent_names = [];
      config_sync = None;
    };
    {
      client_name = "gemini";
      agent_name = "gemini";
      token_env_var = "MASC_GEMINI_MCP_TOKEN";
      server_name = default_server_name;
      login_supported = false;
      login_note = None;
      legacy_agent_names = [];
      config_sync = None;
    };
  ]

let names_for_spec spec = spec.agent_name :: spec.legacy_agent_names

let find_by_agent_name agent_name =
  List.find_opt
    (fun spec -> List.exists (String.equal agent_name) (names_for_spec spec))
    all

let token_env_var_for_agent agent_name =
  match find_by_agent_name agent_name with
  | Some spec -> spec.token_env_var
  | None -> default_token_env_var

let registered_agent agent_name = Option.is_some (find_by_agent_name agent_name)

let dedupe_keep_order values =
  let seen = Hashtbl.create (List.length values) in
  List.filter
    (fun value ->
      if value = "" || Hashtbl.mem seen value then
        false
      else (
        Hashtbl.replace seen value ();
        true))
    values

let agent_names () =
  all |> List.concat_map names_for_spec |> dedupe_keep_order

let config_sync_for_agent agent_name =
  match find_by_agent_name agent_name with
  | Some ({ config_sync = Some sync; _ } as spec) -> Some (spec, sync)
  | Some { config_sync = None; _ } | None -> None

let primary_config_sync_client () =
  match
    List.find_map
      (fun spec ->
        match spec.config_sync with
        | Some sync -> Some (spec, sync)
        | None -> None)
      all
  with
  | Some value -> value
  | None -> invalid_arg "Local_mcp_client_catalog: no config-sync client"
