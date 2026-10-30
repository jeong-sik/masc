let bot_token_opt () = Env_config_core.raw_value_opt "TELEGRAM_BOT_TOKEN" |> Env_config_core.trim_opt

let configured_path names ~default =
  List.find_map (fun name ->
    Env_config_core.raw_value_opt name |> Env_config_core.trim_opt) names
  |> Option.value ~default
  |> Env_config_core.resolve_against_base_path

let binding_store_path () =
  configured_path ["TELEGRAM_BINDING_STORE_PATH"; "MASC_TELEGRAM_BINDING_STORE_PATH"]
    ~default:".gate/runtime/telegram/bindings.json"

let binding_audit_path () =
  configured_path ["TELEGRAM_BINDING_AUDIT_PATH"; "MASC_TELEGRAM_BINDING_AUDIT_PATH"]
    ~default:".gate/runtime/telegram/binding_audit.jsonl"
