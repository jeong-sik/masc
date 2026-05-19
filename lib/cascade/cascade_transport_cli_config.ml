let trim_nonempty value =
  match value with
  | Some raw ->
    let trimmed = String.trim raw in
    if String.equal trimmed "" then None else Some trimmed
  | None -> None
;;

let dedupe_preserve_order (items : string list) =
  let seen = Hashtbl.create (List.length items) in
  List.filter
    (fun item ->
       if Hashtbl.mem seen item
       then false
       else (
         Hashtbl.add seen item ();
         true))
    items
;;

let cli_model_override model_id =
  match String.lowercase_ascii (String.trim model_id) with
  | "" | "auto" -> None
  | _ -> Some (String.trim model_id)
;;

let provider_label (provider_cfg : Llm_provider.Provider_config.t) =
  Printf.sprintf
    "%s:%s"
    (Llm_provider.Provider_config.string_of_provider_kind provider_cfg.kind)
    provider_cfg.model_id
;;

let provider_config_runtime_binding (provider_cfg : Llm_provider.Provider_config.t) =
  Agent_sdk.Provider_runtime_binding.binding_for_provider_config provider_cfg
;;

let runtime_binding_default_model (binding : Agent_sdk.Provider_runtime_binding.t) =
  match trim_nonempty binding.default_model with
  | Some model -> Some model
  | None ->
    (match binding.capabilities.supported_models with
     | Some (model :: _) -> trim_nonempty (Some model)
     | Some [] | None -> None)
;;

let cli_model_for_provider_config (provider_cfg : Llm_provider.Provider_config.t) =
  match cli_model_override provider_cfg.model_id with
  | Some explicit -> Some explicit
  | None -> Option.bind (provider_config_runtime_binding provider_cfg) runtime_binding_default_model
;;

let cli_command_for_provider_config provider_cfg =
  Option.bind (provider_config_runtime_binding provider_cfg) (fun binding ->
    trim_nonempty binding.Agent_sdk.Provider_runtime_binding.command)
;;

let basename_of_command command =
  command
  |> String.split_on_char '/'
  |> List.rev
  |> List.find_opt (fun segment -> String.trim segment <> "")
  |> Option.value ~default:command
;;

let cli_process_name_for_provider_config provider_cfg =
  cli_command_for_provider_config provider_cfg
  |> Option.map basename_of_command
  |> Option.value ~default:"json_stream_cli"
;;

let nonempty_opt value =
  match value with
  | Some value -> trim_nonempty (Some value)
  | None -> None
;;

let direct_binding_candidates_for_cli_binding
      (binding : Agent_sdk.Provider_runtime_binding.t)
  =
  [ binding.credential_scope; binding.command ]
  |> List.filter_map nonempty_opt
  |> dedupe_preserve_order
;;

let binding_is_direct_runtime (binding : Agent_sdk.Provider_runtime_binding.t) =
  match binding.transport with
  | Agent_sdk.Provider_runtime_binding.Http
  | Agent_sdk.Provider_runtime_binding.Managed
  | Agent_sdk.Provider_runtime_binding.Custom_openai_compat -> true
  | Agent_sdk.Provider_runtime_binding.Cli -> false
;;

let direct_binding_for_cli_provider_config provider_cfg =
  match provider_config_runtime_binding provider_cfg with
  | None -> None
  | Some binding ->
    direct_binding_candidates_for_cli_binding binding
    |> List.find_map (fun label ->
      match Agent_sdk.Provider_runtime_binding.find label with
      | Some direct when binding_is_direct_runtime direct -> Some direct
      | Some _
      | None -> None)
;;

let auth_env_names_of_binding (binding : Agent_sdk.Provider_runtime_binding.t) =
  let auth_env =
    match binding.auth with
    | Agent_sdk.Provider_runtime_binding.Api_key_env env
    | Agent_sdk.Provider_runtime_binding.Setup_token_env env -> [ env ]
    | Agent_sdk.Provider_runtime_binding.No_auth
    | Agent_sdk.Provider_runtime_binding.Cli_cached_login
    | Agent_sdk.Provider_runtime_binding.Oauth_cached_login
    | Agent_sdk.Provider_runtime_binding.File _
    | Agent_sdk.Provider_runtime_binding.Exec _ -> []
  in
  binding.api_key_env :: auth_env
  |> List.filter_map (fun env -> trim_nonempty (Some env))
  |> dedupe_preserve_order
;;

let binding_api_base_url (binding : Agent_sdk.Provider_runtime_binding.t) =
  let base_url = String.trim binding.base_url in
  if String.equal base_url ""
  then None
  else (
    let request_path = String.trim binding.request_path in
    if String.equal request_path ""
    then Some base_url
    else (
      let request_path =
        if String.starts_with ~prefix:"/" request_path
        then request_path
        else "/" ^ request_path
      in
      let path_prefix =
        match String.rindex_opt request_path '/' with
        | Some 0
        | None -> ""
        | Some idx -> String.sub request_path 0 idx
      in
      Some (Env_config_core.strip_trailing_slashes base_url ^ path_prefix)))
;;

let first_nonempty_env names =
  List.find_map (fun name -> Sys.getenv_opt name |> trim_nonempty) names
;;

let cli_direct_auth_value
      ?(direct_binding = direct_binding_for_cli_provider_config)
      (provider_cfg : Llm_provider.Provider_config.t)
  =
  match trim_nonempty (Some provider_cfg.api_key) with
  | Some key -> Some key
  | None ->
    (match direct_binding provider_cfg with
     | Some binding -> first_nonempty_env (auth_env_names_of_binding binding)
     | None -> None)
;;

let cli_backing_runtime
      ?(direct_binding = direct_binding_for_cli_provider_config)
      provider_cfg
  =
  Option.bind (direct_binding provider_cfg) (fun binding ->
    match binding_api_base_url binding with
    | Some api_base_url -> Some (binding, api_base_url)
    | None -> None)
;;

let cli_runtime_config_json_for_provider (provider_cfg : Llm_provider.Provider_config.t)
  : string option
  =
  match
    ( cli_model_for_provider_config provider_cfg
    , cli_direct_auth_value provider_cfg
    , cli_backing_runtime provider_cfg )
  with
  | Some model_name, Some _, Some (binding, api_base_url) ->
    let provider_name = binding.Agent_sdk.Provider_runtime_binding.id in
    let max_context_size =
      Cascade_config.resolve_provider_model_max_context
        ~provider_name
        model_name
    in
    let config_json =
      `Assoc
        [ "default_model", `String model_name
        ; ( "providers"
          , `Assoc
              [ ( provider_name
                , `Assoc
                    [ "type", `String provider_name
                    ; "base_url", `String api_base_url
                    ; "api_key", `String ""
                    ] )
              ] )
        ; ( "models"
          , `Assoc
              [ ( model_name
                , `Assoc
                    [ "provider", `String provider_name
                    ; "model", `String model_name
                    ; "max_context_size", `Int max_context_size
                    ] )
              ] )
        ]
    in
    Some (Yojson.Safe.to_string config_json)
  | _ -> None
;;

let cli_direct_binding_extra_env (provider_cfg : Llm_provider.Provider_config.t) =
  match direct_binding_for_cli_provider_config provider_cfg, cli_direct_auth_value provider_cfg with
  | Some binding, Some key ->
    (match auth_env_names_of_binding binding with
     | env_name :: _ -> [ env_name, key ]
     | [] -> [])
  | _ -> []
;;
