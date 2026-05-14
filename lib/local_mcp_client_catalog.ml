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

let default_server_name = "masc"
let default_token_env_var = "MASC_MCP_TOKEN"

let table_opt = function
  | Otoml.TomlTable fields | Otoml.TomlInlineTable fields -> Some fields
  | _ -> None
;;

let find_table_opt key fields = Option.bind (List.assoc_opt key fields) table_opt

let find_any_table_opt keys fields =
  List.find_map (fun key -> find_table_opt key fields) keys
;;

let string_opt key fields =
  match List.assoc_opt key fields with
  | Some (Otoml.TomlString value) ->
    let value = String.trim value in
    if String.equal value "" then None else Some value
  | _ -> None
;;

let string_any_opt keys fields =
  List.find_map (fun key -> string_opt key fields) keys
;;

let bool_opt key fields =
  match List.assoc_opt key fields with
  | Some (Otoml.TomlBoolean value) -> Some value
  | _ -> None
;;

let int_opt key fields =
  match List.assoc_opt key fields with
  | Some (Otoml.TomlInteger value) -> Some value
  | _ -> None
;;

let string_list_opt key fields =
  match List.assoc_opt key fields with
  | Some (Otoml.TomlArray values) ->
    let values =
      List.filter_map
        (function
          | Otoml.TomlString value ->
            let value = String.trim value in
            if String.equal value "" then None else Some value
          | _ -> None)
        values
    in
    Some values
  | _ -> None
;;

let warn_invalid ~provider_id detail =
  Log.warn
    ~ctx:"LocalMcpClientCatalog"
    "ignored providers.%s.mcp_client_config: %s"
    provider_id
    detail
;;

let parse_config_sync ~provider_id fields =
  match find_any_table_opt [ "config-sync"; "config_sync" ] fields with
  | None -> Some None
  | Some sync_fields ->
    (match
       ( string_any_opt [ "enabled-env-var"; "enabled_env_var" ] sync_fields
       , string_any_opt [ "config-path-env-var"; "config_path_env_var" ] sync_fields
       , (match string_list_opt "default-config-path-segments" sync_fields with
          | Some _ as value -> value
          | None -> string_list_opt "default_config_path_segments" sync_fields) )
     with
     | Some enabled_env_var, Some config_path_env_var, Some default_config_path_segments
       when default_config_path_segments <> [] ->
       Some
         (Some { enabled_env_var; config_path_env_var; default_config_path_segments })
     | _ ->
       warn_invalid
         ~provider_id
         "config-sync requires enabled-env-var, config-path-env-var, and non-empty default-config-path-segments";
       None)
;;

let parse_tool_surface = function
  | Some "spawned-agent" -> Some Spawned_agent_tools
  | Some "none" | None -> Some No_spawn_tools
  | Some value ->
    Log.warn
      ~ctx:"LocalMcpClientCatalog"
      "ignored spawn config: unsupported mcp-tool-surface=%S"
      value;
    None
;;

let parse_output_parser = function
  | Some "raw" | None -> Some Spawn_parse_raw
  | Some "result-usage-json" -> Some Spawn_parse_result_usage_json
  | Some "response-usage-json" -> Some Spawn_parse_response_usage_json
  | Some value ->
    Log.warn
      ~ctx:"LocalMcpClientCatalog"
      "ignored spawn config: unsupported output-parser=%S"
      value;
    None
;;

let parse_prompt_mode fields =
  match string_any_opt [ "prompt-mode"; "prompt_mode" ] fields with
  | Some "stdin" | None -> Some Spawn_prompt_stdin
  | Some "flag" ->
    (match string_any_opt [ "prompt-flag"; "prompt_flag" ] fields with
     | Some flag -> Some (Spawn_prompt_flag flag)
     | None ->
       Log.warn
         ~ctx:"LocalMcpClientCatalog"
         "ignored spawn config: prompt-mode=flag requires prompt-flag";
       None)
  | Some value ->
    Log.warn
      ~ctx:"LocalMcpClientCatalog"
      "ignored spawn config: unsupported prompt-mode=%S"
      value;
    None
;;

let parse_mcp_mode fields =
  match string_any_opt [ "mcp-mode"; "mcp_mode" ] fields with
  | Some "none" | None -> Some Spawn_mcp_none
  | Some "joined" ->
    (match string_any_opt [ "mcp-flag"; "mcp_flag" ] fields with
     | Some flag -> Some (Spawn_mcp_joined flag)
     | None ->
       Log.warn
         ~ctx:"LocalMcpClientCatalog"
         "ignored spawn config: mcp-mode=joined requires mcp-flag";
       None)
  | Some "spread" ->
    (match
       ( string_any_opt [ "mcp-server-name"; "mcp_server_name" ] fields
       , string_any_opt [ "mcp-flag"; "mcp_flag" ] fields )
     with
     | Some server_name, Some flag -> Some (Spawn_mcp_spread { server_name; flag })
     | _ ->
       Log.warn
         ~ctx:"LocalMcpClientCatalog"
         "ignored spawn config: mcp-mode=spread requires mcp-server-name and mcp-flag";
       None)
  | Some value ->
    Log.warn
      ~ctx:"LocalMcpClientCatalog"
      "ignored spawn config: unsupported mcp-mode=%S"
      value;
    None
;;

let parse_spawn ~provider_id ~client_name provider_fields =
  match find_any_table_opt [ "spawn" ] provider_fields with
  | None -> Some None
  | Some fields ->
    let command =
      match string_any_opt [ "command"; "argv" ] fields with
      | Some command -> Some command
      | None -> string_opt "command" provider_fields
    in
    (match command with
     | None ->
       Log.warn
         ~ctx:"LocalMcpClientCatalog"
         "ignored providers.%s.spawn: command is required"
         provider_id;
       None
     | Some command ->
       let agent_name =
         string_any_opt [ "agent-name"; "agent_name" ] fields
         |> Option.value ~default:client_name
       in
       let aliases =
         match string_list_opt "aliases" fields with
         | Some aliases -> aliases
         | None -> string_list_opt "alias" fields |> Option.value ~default:[]
       in
       let timeout_seconds =
         match int_opt "timeout-seconds" fields with
         | Some _ as value -> value
         | None -> int_opt "timeout_seconds" fields
       in
       let working_dir = string_any_opt [ "working-dir"; "working_dir" ] fields in
       let tool_surface =
         parse_tool_surface
           (string_any_opt [ "mcp-tool-surface"; "mcp_tool_surface" ] fields)
       in
       let output_parser =
         parse_output_parser
           (string_any_opt [ "output-parser"; "output_parser" ] fields)
       in
       let prompt_mode = parse_prompt_mode fields in
       let mcp_mode = parse_mcp_mode fields in
       (match tool_surface, output_parser, prompt_mode, mcp_mode with
        | Some tool_surface, Some output_parser, Some prompt_mode, Some mcp_mode ->
          let stdin_prompt =
            bool_opt "stdin-prompt" fields
            |> Option.value
                 ~default:
                   (bool_opt "stdin_prompt" fields
                    |> Option.value
                         ~default:
                           (match prompt_mode with
                            | Spawn_prompt_stdin -> true
                            | Spawn_prompt_flag _ -> false))
          in
          Some
            (Some
               { agent_name
               ; aliases
               ; command
               ; timeout_seconds
               ; working_dir
               ; tool_surface
               ; output_parser
               ; stdin_prompt
               ; mcp_mode
               ; prompt_mode
               })
        | _ -> None))
;;

let parse_provider_mcp_client ~provider_id provider_fields =
  let mcp_fields =
    find_any_table_opt [ "mcp_client_config"; "mcp-client-config" ] provider_fields
  in
  let has_spawn = Option.is_some (find_any_table_opt [ "spawn" ] provider_fields) in
  match mcp_fields, has_spawn with
  | None, false -> None
  | _ ->
    let fields = Option.value mcp_fields ~default:[] in
    let client_name =
      string_any_opt [ "client-name"; "client_name" ] fields
      |> Option.value ~default:provider_id
    in
    let agent_name =
      string_any_opt [ "agent-name"; "agent_name" ] fields
      |> Option.value ~default:client_name
    in
    let token_env_var =
      string_any_opt [ "token-env-var"; "token_env_var" ] fields
      |> Option.value ~default:default_token_env_var
    in
    let server_name =
      string_any_opt [ "server-name"; "server_name" ] fields
      |> Option.value ~default:default_server_name
    in
    let login_supported =
      bool_opt "login-supported" fields
      |> Option.value
           ~default:
             (bool_opt "login_supported" fields |> Option.value ~default:false)
    in
    let login_note = string_any_opt [ "login-note"; "login_note" ] fields in
    let legacy_agent_names =
      match string_list_opt "legacy-agent-names" fields with
      | Some names -> names
      | None ->
        string_list_opt "legacy_agent_names" fields |> Option.value ~default:[]
    in
    (match parse_config_sync ~provider_id fields with
     | None -> None
     | Some config_sync ->
       (match parse_spawn ~provider_id ~client_name provider_fields with
        | None -> None
        | Some spawn ->
          Some
            { provider_id
            ; client_name
            ; agent_name
            ; token_env_var
            ; server_name
            ; login_supported
            ; login_note
            ; legacy_agent_names
            ; config_sync
            ; spawn
            }))
;;

let load_from_toml path =
  try
    match Otoml.Parser.from_string_result (Fs_compat.load_file path) with
    | Error msg ->
      Log.warn
        ~ctx:"LocalMcpClientCatalog"
        "failed to parse cascade TOML for MCP client catalog: %s"
        msg;
      []
    | Ok toml ->
      let root_fields = table_opt toml |> Option.value ~default:[] in
      (match find_table_opt "providers" root_fields with
       | None -> []
       | Some providers ->
         providers
         |> List.filter_map (fun (provider_id, provider_value) ->
           Option.bind (table_opt provider_value) (parse_provider_mcp_client ~provider_id)))
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Log.warn
      ~ctx:"LocalMcpClientCatalog"
      "failed to load MCP client catalog: %s"
      (Printexc.to_string exn);
    []
;;

let existing_file_opt path =
  try if Sys.file_exists path then Some path else None with
  | Sys_error _ -> None
;;

let cascade_path_opt () =
  match Config_dir_resolver.cascade_path_opt () with
  | Some _ as value -> value
  | None ->
    [ Sys.getenv_opt "DUNE_SOURCEROOT"
      |> Env_config_core.trim_opt
      |> Option.map (fun root -> Filename.concat root "config/cascade.toml")
    ; Some (Filename.concat (Sys.getcwd ()) "config/cascade.toml")
    ]
    |> List.filter_map Fun.id
    |> List.find_map existing_file_opt
;;

let all () =
  match cascade_path_opt () with
  | Some path -> load_from_toml path
  | None -> []
;;

let names_for_spec spec = spec.agent_name :: spec.legacy_agent_names

let find_by_agent_name agent_name =
  List.find_opt
    (fun spec -> List.exists (String.equal agent_name) (names_for_spec spec))
    (all ())

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
  all () |> List.concat_map names_for_spec |> dedupe_keep_order

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
      (all ())
  with
  | Some value -> value
  | None -> invalid_arg "Local_mcp_client_catalog: no config-sync client"

let spawn_names _spec (spawn : spawn) =
  dedupe_keep_order (spawn.agent_name :: spawn.aliases)

let find_spawn agent_name =
  let normalized = String.lowercase_ascii (String.trim agent_name) in
  all ()
  |> List.find_map (fun spec ->
    match spec.spawn with
    | None -> None
    | Some spawn ->
      if
        List.exists
          (fun name -> String.equal normalized (String.lowercase_ascii name))
          (spawn_names spec spawn)
      then Some (spec, spawn)
      else None)

let executable_name command =
  String.split_on_char ' ' (String.trim command)
  |> List.find_opt (fun part -> not (String.equal part ""))
  |> Option.map Filename.basename

let audited_spawn_executables () =
  all ()
  |> List.filter_map (fun spec ->
    match spec.spawn with
    | Some spawn -> executable_name spawn.command
    | None -> None)
  |> dedupe_keep_order
