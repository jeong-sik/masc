let bot_token_opt () = Env_config_core.raw_value_opt "TELEGRAM_BOT_TOKEN" |> Env_config_core.trim_opt

let configured_path names ~filename =
  match List.find_map (fun name ->
    Env_config_core.raw_value_opt name |> Env_config_core.trim_opt) names with
  | Some raw -> Env_config_core.resolve_against_base_path raw
  | None ->
    Filename.concat
      (Common.connector_state_dir_of_base
         ~base_path:(Env_config_core.base_path ()) Common.Connector_telegram)
      filename

let binding_store_path () =
  configured_path ["TELEGRAM_BINDING_STORE_PATH"; "MASC_TELEGRAM_BINDING_STORE_PATH"]
    ~filename:Common.connector_bindings_filename

let binding_audit_path () =
  configured_path ["TELEGRAM_BINDING_AUDIT_PATH"; "MASC_TELEGRAM_BINDING_AUDIT_PATH"]
    ~filename:Common.connector_binding_audit_filename
