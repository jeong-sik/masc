(* Verification must not inherit MCP servers, plugins, hooks, or instructions.
   Only connection/auth configuration is projected into this private home. *)
let connection_key = function
  | "model" | "model_provider" | "model_reasoning_effort"
  | "model_providers" | "chatgpt_base_url" | "forced_login_method"
  | "forced_chatgpt_workspace_id" -> true
  | _ -> false
;;

let project_config ?(disabled_mcp_servers = []) body =
  try match Otoml.Parser.from_string_result body with
  | Error _ -> Error "The Codex connection configuration could not be parsed."
  | Ok doc ->
    let fields = Otoml.get_table doc in
    let projected = List.filter (fun (key, _) -> connection_key key) fields in
    let profile =
      match List.assoc_opt "profile" fields, List.assoc_opt "profiles" fields with
      | Some (Otoml.TomlString name), Some profiles ->
        (match Otoml.find_opt profiles Fun.id [ name ] with
         | Some profile -> List.filter (fun (key, _) -> connection_key key) (Otoml.get_table profile)
         | None -> raise (Otoml.Type_error "Selected Codex profile is not declared"))
      | None, _ -> []
      | Some _, _ -> raise (Otoml.Type_error "Selected Codex profile cannot be safely projected")
    in
    let projected = List.filter (fun (key, _) -> not (List.mem_assoc key profile)) projected @ profile in
    Ok (Otoml.Printer.to_string (Otoml.TomlTable (projected @ [
      "mcp_servers", Otoml.TomlTable (List.map (fun name -> name,
        Otoml.TomlTable ["enabled", Otoml.TomlBoolean false]) disabled_mcp_servers);
      "cli_auth_credentials_store", Otoml.TomlString "file";
      "web_search", Otoml.TomlString "disabled";
      "features", Otoml.TomlTable (List.map (fun key -> key, Otoml.TomlBoolean false)
        [ "apps"; "plugins"; "hooks"; "enable_mcp_apps"; "skill_search";
          "skill_mcp_dependency_install"; "multi_agent"; "multi_agent_v2";
          "browser_use"; "browser_use_external"; "browser_use_full_cdp_access";
          "computer_use"; "in_app_browser"; "shell_tool"; "unified_exec" ])
    ])))
  with Otoml.Type_error _ -> Error "The Codex connection configuration has invalid field types."
;;

let server_names body =
  let doc = Otoml.Parser.from_string body in
  match Otoml.find_opt doc Otoml.get_table [ "mcp_servers" ] with
  | None -> []
  | Some servers -> List.map fst servers
;;

let disabled_server_names ~home =
  server_names (Fs_compat.load_file (Filename.concat home "config.toml"))
;;

let cli_overrides ~home =
  let doc = Otoml.Parser.from_string
    (Fs_compat.load_file (Filename.concat home "config.toml")) in
  let features = match Otoml.find_opt doc Otoml.get_table ["features"] with
    | None -> []
    | Some fields -> List.map (fun (name, _) ->
      Printf.sprintf "features.\"%s\"=false" (Toml_line_editor.escape_string name)) fields in
  [ "web_search=\"disabled\""; "cli_auth_credentials_store=\"file\"" ] @ features @
  (disabled_server_names ~home |> List.map (fun name ->
    Printf.sprintf "mcp_servers.\"%s\".enabled=false" (Toml_line_editor.escape_string name)))
;;

let inherited_server_names ~directory =
  let rec ancestors path =
    let config = Filename.concat path ".codex/config.toml" in
    let parent = Filename.dirname path in
    config :: (if parent = path then [] else ancestors parent)
  in
  (* Codex's documented Unix system configuration layer is independent of
     CODEX_HOME. CLI overrides below outrank it and project ancestor layers. *)
  (* The original user home is absent from the isolated client's layers.
     Do not add disabled-only entries for those absent servers: Codex still
     requires a transport definition even when a server is disabled. *)
  let paths = "/etc/codex/config.toml" :: ancestors directory in
  paths |> List.concat_map (fun path ->
    if Sys.file_exists path then server_names (Fs_compat.load_file path) else [])
  |> List.sort_uniq String.compare
;;

let prepare ~directory =
  try let source =
    match Sys.getenv_opt "CODEX_HOME" with
    | Some value when String.trim value <> "" -> Env_config.normalize_masc_base_path_input value
    | _ -> Filename.concat (Sys.getenv "HOME") ".codex"
  in
  let source = if Filename.is_relative source then Filename.concat (Sys.getcwd ()) source else source in
  let source_config = Filename.concat source "config.toml" in
  let body = if Sys.file_exists source_config then Fs_compat.load_file source_config else "" in
  match project_config ~disabled_mcp_servers:(inherited_server_names ~directory) body with
  | Error _ as error -> error
  | Ok config ->
    let destination = Filename.concat directory "codex-home" in
    Unix.mkdir destination 0o700;
    let write name content =
      let channel = open_out_gen [ Open_wronly; Open_creat; Open_excl; Open_binary ] 0o600
        (Filename.concat destination name) in
      Fun.protect ~finally:(fun () -> close_out channel) (fun () -> output_string channel content)
    in
    write "config.toml" config;
    let auth = Filename.concat source "auth.json" in
    if Sys.file_exists auth then write "auth.json" (Fs_compat.load_file auth);
    Ok destination
  with
  | Not_found -> Error "HOME is required to find the Codex connection credentials."
  | Otoml.Type_error _ | Otoml.Parse_error _ ->
    Error "An inherited Codex configuration could not be inspected safely."
;;
