(** Runtime-lens support summaries for keeper runtime trace responses.

    Split from {!Server_dashboard_http_keeper_api}; these summaries read
    keeper tool-call and config state but do not assemble HTTP responses. *)


let config_drift_summary_json ~config ~keeper_name =
  match Keeper_meta_store.read_meta config keeper_name with
  | Error message ->
    `Assoc
      [ ("present", `Bool false)
      ; ("status", `String "read_error")
      ; ("error", `String message)
      ; ("has_live_override", `Bool false)
      ; ("runtime_override", `Bool false)
      ; ("override_fields", `List [])
      ; ("default_runtime_id", `Null)
      ; ("live_runtime_id", `Null)
      ; ("active_config_root", `Null)
      ; ("active_config_root_source", `Null)
      ]
  | Ok None ->
    `Assoc
      [ ("present", `Bool false)
      ; ("status", `String "keeper_missing")
      ; ("error", `Null)
      ; ("has_live_override", `Bool false)
      ; ("runtime_override", `Bool false)
      ; ("override_fields", `List [])
      ; ("default_runtime_id", `Null)
      ; ("live_runtime_id", `Null)
      ; ("active_config_root", `Null)
      ; ("active_config_root_source", `Null)
      ]
  | Ok (Some meta) ->
    let sources = Keeper_status_bridge.source_provenance config meta in
    let override_fields =
      List.map Keeper_status_bridge_override.field_name sources.overrides
    in
    let runtime_drift = Keeper_status_bridge_override.runtime_drift sources.overrides in
    let default_runtime_id, live_runtime_id =
      match runtime_drift with
      | Some { default; live } -> Some default, Some live
      | None -> None, None
    in
    let runtime_override = Option.is_some runtime_drift in
    `Assoc
      [ ("present", `Bool true)
      ; ("status", `String (if runtime_override then "drift" else "ok"))
      ; ("error", `Null)
      ; ("has_live_override", `Bool (sources.overrides <> []))
      ; ("runtime_override", `Bool runtime_override)
      ; ("override_fields", Json_util.json_string_list override_fields)
      ; ("default_runtime_id", Json_util.string_opt_to_json default_runtime_id)
      ; ("live_runtime_id", Json_util.string_opt_to_json live_runtime_id)
      ; ("active_config_root", `String (Keeper_status_bridge.active_config_root sources))
      ; ( "active_config_root_source",
          `String (Keeper_status_bridge.active_config_root_source sources) )
      ; ( "default_manifest_path",
          Json_util.string_opt_to_json sources.default_manifest_path )
      ]
