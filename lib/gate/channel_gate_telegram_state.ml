include
  Channel_gate_sidecar_state.Make
    (struct
      let connector_id = "telegram"
      let display_name = "Telegram"
      let channel = "telegram"
      let status_path_env_names =
        [ "TELEGRAM_STATUS_PATH"; "MASC_TELEGRAM_STATUS_PATH" ]
      let binding_store_path_env_names =
        [ "TELEGRAM_BINDING_STORE_PATH"; "MASC_TELEGRAM_BINDING_STORE_PATH" ]
      let binding_audit_path_env_names =
        [ "TELEGRAM_BINDING_AUDIT_PATH"; "MASC_TELEGRAM_BINDING_AUDIT_PATH" ]
      let stale_after_env_name = "MASC_TELEGRAM_STATUS_STALE_SEC"
    end)
