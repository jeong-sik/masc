(** Runtime-lens support summaries for keeper runtime trace responses.

    Split from {!Server_dashboard_http_keeper_api}; these summaries read
    keeper tool-call and config state but do not assemble HTTP responses. *)

open Server_dashboard_http_keeper_api_types

let json_string_list values = `List (List.map (fun value -> `String value) values)

let claim_scope_summary_json ~keeper_name ~trace_id ?turn_id () =
  let entries = Keeper_tool_call_log.read_recent ~keeper_name ~n:200 () in
  let matching_claim =
    entries
    |> List.find_opt (fun json ->
      String.equal
        (Option.value ~default:"" (json_string_member_opt "tool" json))
        "keeper_task_claim"
      && tool_call_matches_trace ?turn_id ~keeper_name ~trace_id json)
  in
  match matching_claim with
  | None -> claim_scope_summary_absent
  | Some call ->
    let output =
      match parse_tool_output_json_opt call with
      | Some (`Assoc _ as output) -> output
      | _ -> `Assoc []
    in
    let claim_scope =
      match json_assoc_member_opt "claim_scope" output with
      | Some scope -> scope
      | None -> `Assoc []
    in
    let claimed_task = json_assoc_member_opt "claimed_task" output in
    `Assoc
      [ ("present", `Bool true)
      ; ("source", `String "keeper_task_claim_tool_call")
      ; ("status", `String (claim_status_of_output output))
      ; ("result", json_string_opt (json_string_member_opt "result" output))
      ; ("mode", json_string_opt (json_string_member_opt "mode" claim_scope))
      ; ( "scoped",
          match json_bool_member_opt "scoped" claim_scope with
          | Some value -> `Bool value
          | None -> `Null )
      ; ( "active_goal_ids",
          json_string_list (json_string_list_member "active_goal_ids" claim_scope) )
      ; ( "effective_goal_ids",
          json_string_list
            (json_string_list_member "effective_goal_ids" claim_scope) )
      ; ( "fallback_reason",
          json_string_opt (json_string_member_opt "fallback_reason" claim_scope) )
      ; ( "matched_goal_id",
          json_string_opt (json_string_member_opt "matched_goal_id" claim_scope) )
      ; ( "excluded_count",
          match json_int_member_opt "excluded_count" claim_scope with
          | Some value -> `Int value
          | None -> `Null )
      ; ( "claimed_task_id",
          match claimed_task with
          | Some task -> json_string_opt (json_string_member_opt "task_id" task)
          | None -> `Null )
      ; ( "claimed_goal_id",
          match claimed_task with
          | Some task -> json_string_opt (json_string_member_opt "goal_id" task)
          | None -> `Null )
      ; ("trace_id", json_string_opt (json_string_member_opt "trace_id" call))
      ; ( "keeper_turn_id",
          match json_int_member_opt "keeper_turn_id" call with
          | Some value -> `Int value
          | None -> `Null )
      ]

let find_override_field_source field sources =
  match Yojson.Safe.Util.member "override_field_sources" sources with
  | `List values ->
    List.find_opt
      (fun value -> json_string_member_opt "field" value = Some field)
      values
  | _ -> None

let config_drift_summary_json ~config ~keeper_name =
  match Keeper_types.read_meta config keeper_name with
  | Error message ->
    `Assoc
      [ ("present", `Bool false)
      ; ("status", `String "read_error")
      ; ("error", `String message)
      ; ("has_live_override", `Bool false)
      ; ("cascade_override", `Bool false)
      ; ("override_fields", `List [])
      ; ("default_cascade_name", `Null)
      ; ("live_cascade_name", `Null)
      ; ("active_config_root", `Null)
      ; ("active_config_root_source", `Null)
      ]
  | Ok None ->
    `Assoc
      [ ("present", `Bool false)
      ; ("status", `String "keeper_missing")
      ; ("error", `Null)
      ; ("has_live_override", `Bool false)
      ; ("cascade_override", `Bool false)
      ; ("override_fields", `List [])
      ; ("default_cascade_name", `Null)
      ; ("live_cascade_name", `Null)
      ; ("active_config_root", `Null)
      ; ("active_config_root_source", `Null)
      ]
  | Ok (Some meta) ->
    let sources = Keeper_status_bridge.source_provenance_json config meta in
    let override_fields = json_string_list_member "override_fields" sources in
    let cascade_detail = find_override_field_source "model.cascade_name" sources in
    let default_cascade_name, live_cascade_name =
      match cascade_detail with
      | Some detail ->
        ( Yojson.Safe.Util.member "default_value" detail |> json_string_value_opt,
          Yojson.Safe.Util.member "live_value" detail |> json_string_value_opt )
      | None -> (None, None)
    in
    let cascade_override = Option.is_some cascade_detail in
    `Assoc
      [ ("present", `Bool true)
      ; ("status", `String (if cascade_override then "drift" else "ok"))
      ; ("error", `Null)
      ; ( "has_live_override",
          `Bool
            (Option.value
               (json_bool_member_opt "has_live_override" sources)
               ~default:false) )
      ; ("cascade_override", `Bool cascade_override)
      ; ("override_fields", json_string_list override_fields)
      ; ("default_cascade_name", json_string_opt default_cascade_name)
      ; ("live_cascade_name", json_string_opt live_cascade_name)
      ; ( "active_config_root",
          json_string_opt (json_string_member_opt "active_config_root" sources) )
      ; ( "active_config_root_source",
          json_string_opt
            (json_string_member_opt "active_config_root_source" sources) )
      ; ( "default_manifest_path",
          json_string_opt (json_string_member_opt "default_manifest_path" sources) )
      ]
