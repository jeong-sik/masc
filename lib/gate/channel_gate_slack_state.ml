include
  Channel_gate_sidecar_state.Make
    (struct
      let connector_id = "slack"
      let display_name = "Slack"
      let channel = "slack"
      let default_status_path = ".gate/runtime/slack/status.json"
      let default_binding_store_path = ".gate/runtime/slack/bindings.json"
      let default_binding_audit_path = ".gate/runtime/slack/binding_audit.jsonl"
      let status_path_env_names =
        [ "SLACK_STATUS_PATH"; "MASC_SLACK_STATUS_PATH" ]
      let binding_store_path_env_names =
        [ "SLACK_BINDING_STORE_PATH"; "MASC_SLACK_BINDING_STORE_PATH" ]
      let binding_audit_path_env_names =
        [ "SLACK_BINDING_AUDIT_PATH"; "MASC_SLACK_BINDING_AUDIT_PATH" ]
      let stale_after_env_name = "MASC_SLACK_STATUS_STALE_SEC"
    end)
