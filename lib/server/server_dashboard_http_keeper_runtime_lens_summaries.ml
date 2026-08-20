(** Runtime-lens support summaries for keeper runtime trace responses.

    Split from {!Server_dashboard_http_keeper_api}; these summaries read
    keeper tool-call and config state but do not assemble HTTP responses. *)


let find_override_field_source field sources =
  match Json_util.assoc_member_opt "override_field_sources" sources with
  | Some (`List values) ->
    List.find_opt
      (fun value -> Json_util.get_string value "field" = Some field)
      values
  | None | Some _ -> None

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
    let sources = Keeper_status_bridge.source_provenance_json config meta in
    let override_fields = Json_util.get_string_list sources "override_fields" in
    let runtime_detail = find_override_field_source "model.runtime_id" sources in
    let default_runtime_id, live_runtime_id =
      match runtime_detail with
      | Some detail ->
        ( Json_util.get_string detail "default_value",
          Json_util.get_string detail "live_value" )
      | None -> (None, None)
    in
    let runtime_override = Option.is_some runtime_detail in
    `Assoc
      [ ("present", `Bool true)
      ; ("status", `String (if runtime_override then "drift" else "ok"))
      ; ("error", `Null)
      ; ( "has_live_override",
          `Bool
            (Option.value
               (Json_util.get_bool sources "has_live_override")
               ~default:false) )
      ; ("runtime_override", `Bool runtime_override)
      ; ("override_fields", Json_util.json_string_list override_fields)
      ; ("default_runtime_id", Json_util.string_opt_to_json default_runtime_id)
      ; ("live_runtime_id", Json_util.string_opt_to_json live_runtime_id)
      ; ( "active_config_root",
          Json_util.string_opt_to_json (Json_util.get_string sources "active_config_root") )
      ; ( "active_config_root_source",
          Json_util.string_opt_to_json
            (Json_util.get_string sources "active_config_root_source") )
      ; ( "default_manifest_path",
          Json_util.string_opt_to_json (Json_util.get_string sources "default_manifest_path") )
      ]
