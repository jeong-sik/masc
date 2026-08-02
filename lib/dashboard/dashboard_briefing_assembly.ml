(** Dashboard_briefing_assembly — keeper briefs, operation contexts,
    session assembly, internal signals, and timeline rendering for the dashboard.

    Agent briefs and related helpers are in Dashboard_briefing_agents. *)

(** Context ratio above which a keeper gets elevated lane pressure rank. *)
let lane_pressure_ctx_ratio = 0.80

include Dashboard_briefing_agents

let keeper_tool_audit_json_fields config _registry_lookup keeper agent_name =
  let keeper_name =
    match member_assoc "name" keeper with
    | `String n ->
        (match String_util.trim_to_option n with Some v -> v | None -> agent_name)
    | _ -> agent_name
  in
  let fallback_latest =
    Dashboard_utils.string_list_of_json (member_assoc "latest_tool_names" keeper)
  in
  let fallback_count = Json_util.assoc_int_opt "latest_tool_call_count" keeper in
  let fallback_source =
    match String_util.trim_to_option (string_field "tool_audit_source" keeper) with
    | Some _ as value -> value
    | None -> None
  in
  let fallback_action_source =
    String_util.trim_to_option (string_field "latest_action_source" keeper)
  in
  let fallback_at =
    String_util.trim_to_option (string_field "tool_audit_at" keeper)
  in
  let file_snapshot =
    let keeper_updated_at =
      String_util.trim_to_option (string_field "updated_at" keeper)
    in
    match
      Keeper_status_metrics.latest_tool_audit_snapshot_from_files config
        ~keeper_name
    with
    | Some snapshot ->
        Some
          {
            snapshot with
            tool_audit_at =
              (match snapshot.tool_audit_source, snapshot.tool_audit_at, keeper_updated_at with
               | Some _, None, Some updated_at -> Some updated_at
               | _ -> snapshot.tool_audit_at);
          }
    | None -> None
  in
  let latest_tool_names, latest_tool_call_count, latest_action_source,
      tool_audit_source, tool_audit_at =
    (match file_snapshot with
        | Some snapshot ->
            ( snapshot.latest_tool_names,
              snapshot.latest_tool_call_count,
              snapshot.latest_action_source,
              snapshot.tool_audit_source,
              snapshot.tool_audit_at )
        | None ->
            (* Use per-keeper tool tracking as last-resort fallback *)
            let tracked = Keeper_tools_oas.tool_usage_for_keeper agent_name in
            if tracked <> [] then
              let names = List.map fst tracked in
              let total = List.fold_left (fun acc (_, e) -> acc + e.Keeper_types.count) 0 tracked in
              let latest_at = List.fold_left (fun acc (_, e) ->
                max acc e.Keeper_types.last_used_at) 0.0 tracked in
              let at_str = if latest_at > 0.0
                then Some (Masc_domain.iso8601_of_unix_seconds latest_at) else None in
              (names, Some total, None, Some "keeper_dispatch", at_str)
            else
              ( fallback_latest,
                fallback_count,
                fallback_action_source,
                fallback_source,
                fallback_at ))
  in
  [
    ("latest_tool_names", Json_util.json_string_list latest_tool_names);
    ( "latest_tool_call_count",
      Json_util.option_to_yojson (fun value -> `Int value) latest_tool_call_count );
    ("latest_action_source", Json_util.string_opt_to_json latest_action_source);
    ("tool_audit_source", Json_util.string_opt_to_json tool_audit_source);
    ("tool_audit_at", Json_util.string_opt_to_json tool_audit_at);
  ]

let action_identity action =
  String.concat "|"
    [
      string_field "action_type" action;
      string_field "target_type" action;
      Option.value ~default:"none" (String_util.trim_to_option (string_field "target_id" action));
      normalized_text_key (string_field "reason" action);
    ]

let incident_identity incident =
  String.concat "|"
    [
      string_field "kind" incident;
      string_field "target_type" incident;
      Option.value ~default:"none" (String_util.trim_to_option (string_field "target_id" incident));
      normalized_text_key (string_field "summary" incident);
    ]

let identity_digest prefix identity =
  Printf.sprintf "%s:%s" prefix (Digest.to_hex (Digest.string identity))

let is_internal_attention incident =
  Operator_digest_types.is_workspace_target_type
    (string_field "target_type" incident)

let is_internal_action action =
  Operator_digest_types.is_workspace_target_type
    (string_field "target_type" action)

let incident_action_types kind =
  match kind with
  | "spawn_failure_present" -> [ "task_inject" ]
  | "detached_actor_present"
  | "empty_note_turn_present"
  | "low_confidence_routing"
  | "routing_escalation_present" -> [ "broadcast" ]
  | "planned_worker_without_turn" -> [ "task_inject"; "broadcast" ]
  | "local64_role_gap" -> [ "task_inject" ]
  | "stalled_session" -> [ "namespace_pause" ]
  | "command_issue_pressure"
  | "command_routing_confidence"
  | "command_quality_per_token"
  | "command_verification_gate_failures"
  | "command_rework_rate"
  | "command_artifact_scope_drift"
  | "command_cache_contention"
  | "command_speculative_posture"
  | "intent_blocked"
  | "intent_handoff_ready" -> [ "broadcast" ]
  | _ -> []

let action_matches_incident incident action =
  let target_type = string_field "target_type" incident in
  let target_id = String_util.trim_to_option (string_field "target_id" incident) in
  let action_target_type = string_field "target_type" action in
  let action_target_id = String_util.trim_to_option (string_field "target_id" action) in
  let same_target =
    String.equal action_target_type target_type
    &&
    match target_id, action_target_id with
    | Some left, Some right -> String.equal left right
    | None, None -> true
    | _ -> false
  in
  if not same_target then false
  else
    let incident_summary = normalized_text_key (string_field "summary" incident) in
    let action_reason = normalized_text_key (string_field "reason" action) in
    let reason_matches =
      incident_summary <> "" && action_reason <> ""
      && String.equal incident_summary action_reason
    in
    if reason_matches then true
    else
      let action_type = string_field "action_type" action in
      List.mem action_type (incident_action_types (string_field "kind" incident))

let build_keeper_briefs (config : Workspace.config) (keepers : Yojson.Safe.t list) =
  let all_entries = Keeper_registry.all ~base_path:config.base_path () in
  let registry_lookup name =
    List.find_opt (fun (e : Keeper_registry.registry_entry) -> String.equal e.name name) all_entries
  in
  keepers
  |> List.filter_map (fun keeper ->
         let name = string_field "name" keeper in
         if name = "" then None
         else
           let status =
             string_field "status" keeper
           in
           let context_ratio =
             match member_assoc "context_ratio" keeper with
             | `Float value -> Some value
             | `Int value -> Some (float_of_int value)
             | _ -> None
           in
           let context_metrics_unavailable =
             member_assoc "context_metrics_unavailable" keeper
           in
           let pressure_rank =
             if Dashboard_utils.is_keeper_offline status then 3
             else if
               Option.exists
                 (fun ratio -> ratio >= lane_pressure_ctx_ratio)
                 context_ratio
             then
               2
             else if status = "idle" then 1
             else 0
           in
           Some
             {
               pressure_rank;
               last_seen_ts =
                 Dashboard_utils.parse_iso_opt
                   (String_util.trim_to_option
                      (match String_util.trim_to_option (string_field "last_autonomous_action_at" keeper) with
                      | Some value -> value
                      | None -> string_field "updated_at" keeper))
                 |> Option.value ~default:0.0;
               json =
                 `Assoc
                   ([
                      ("name", `String name);
                      ("agent_name", member_assoc "agent_name" keeper);
                      ("status", `String status);
                      ("generation", member_assoc "generation" keeper);
                      ("context_ratio", Json_util.option_to_yojson (fun value -> `Float value) context_ratio);
                      ("context_metrics_unavailable", context_metrics_unavailable);
                      ("last_turn_ago_s", member_assoc "last_turn_ago_s" keeper);
                      ( "current_work",
                        Json_util.string_opt_to_json
                          (Dashboard_utils.string_list_of_json
                             (member_assoc "active_goal_ids" keeper)
                           |> function
                           | current :: _ -> Some current
                           | [] -> None) );
                      ("last_autonomous_action_at", member_assoc "last_autonomous_action_at" keeper);
                      ("proactive_enabled", member_assoc "proactive_enabled" keeper);
                      ("paused", member_assoc "paused" keeper);
                      ("exclusion_reason",
                       Keeper_runtime.autoboot_exclusion_reason_opt_to_yojson
                         (Keeper_runtime.autoboot_exclusion_reason config name));
                    ]
                    @ keeper_tool_audit_json_fields config registry_lookup keeper
                        (match String_util.trim_to_option (string_field "agent_name" keeper) with
                         | Some agent_name -> agent_name
                         | None -> name));
             })
  |> List.sort (fun left right ->
         let by_pressure = Int.compare right.pressure_rank left.pressure_rank in
         if by_pressure <> 0 then by_pressure
         else Float.compare right.last_seen_ts left.last_seen_ts)
  |> List.map (fun (row : keeper_context) -> row.json)

let build_internal_signals incidents actions =
  let internal_incidents =
    incidents
    |> List.filter is_internal_attention
    |> List.map (fun incident ->
           let action = List.find_opt (action_matches_incident incident) actions in
           {
             pressure_rank = severity_rank (string_field ~default:"warn" "severity" incident);
             last_seen_ts = 0.0;
             json =
               `Assoc
                 [
                   ("id", `String (identity_digest "attention" (incident_identity incident)));
                   ("signal_type", `String "attention");
                   ("severity", member_assoc "severity" incident);
                   ("summary", member_assoc "summary" incident);
                   ("target_type", member_assoc "target_type" incident);
                   ("target_id", member_assoc "target_id" incident);
                   ("attention", incident);
                   ("action", Json_util.option_to_yojson (fun value -> value) action);
                 ];
           })
  in
  let matched_internal_action_keys =
    internal_incidents
    |> List.filter_map (fun row ->
           match member_assoc "action" row.json with
           | `Assoc _ as action -> Some (action_identity action)
           | _ -> None)
  in
  let internal_actions =
    actions
    |> List.filter is_internal_action
    |> List.filter (fun action ->
           not (List.mem (action_identity action) matched_internal_action_keys))
    |> List.map (fun action ->
           {
             pressure_rank = severity_rank (string_field ~default:"warn" "severity" action);
             last_seen_ts = 0.0;
             json =
               `Assoc
                 [
                   ("id", `String (identity_digest "action" (action_identity action)));
                   ("signal_type", `String "action");
                   ("severity", member_assoc "severity" action);
                   ("summary", member_assoc "reason" action);
                   ("target_type", member_assoc "target_type" action);
                   ("target_id", member_assoc "target_id" action);
                   ("attention", `Null);
                   ("action", action);
                 ];
           })
  in
  (internal_incidents @ internal_actions)
  |> List.sort (fun left right -> Int.compare right.pressure_rank left.pressure_rank)
  |> List.map (fun (row : keeper_context) -> row.json)
