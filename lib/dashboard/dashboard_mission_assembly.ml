(** Dashboard_mission_assembly — keeper briefs, operation contexts,
    session assembly, internal signals, and timeline rendering for the mission dashboard.

    Agent briefs and related helpers are in Dashboard_mission_agents. *)

(** Context ratio above which a keeper gets elevated lane pressure rank. *)
let lane_pressure_ctx_ratio = 0.80

include Dashboard_mission_agents

let keeper_tool_audit_json_fields config registry_lookup keeper agent_name =
  let keeper_name =
    match member_assoc "name" keeper with
    | `String n when String.trim n <> "" -> String.trim n
    | _ -> agent_name
  in
  let fallback_allowed =
    let raw_allowed = member_assoc "allowed_tool_names" keeper in
    match raw_allowed with
    | `Null ->
        (* Realtime fallback: compute from registry meta when JSON field is absent/null *)
        (match registry_lookup keeper_name with
         | Some (entry : Keeper_registry.registry_entry) ->
           Keeper_exec_tools.keeper_allowed_tool_names entry.meta
         | None -> [])
    | _ -> string_list_of_json raw_allowed
  in
  let fallback_latest =
    string_list_of_json (member_assoc "latest_tool_names" keeper)
  in
  let fallback_count =
    match member_assoc "latest_tool_call_count" keeper with
    | `Int value -> Some value
    | `Intlit raw -> (int_of_string_opt (raw))
    | _ -> None
  in
  let fallback_source =
    match trim_to_option (string_field "tool_audit_source" keeper) with
    | Some _ as value -> value
    | None -> None
  in
  let fallback_action_source =
    trim_to_option (string_field "latest_action_source" keeper)
  in
  let fallback_at =
    trim_to_option (string_field "tool_audit_at" keeper)
  in
  let file_snapshot =
    let keeper_updated_at =
      trim_to_option (string_field "updated_at" keeper)
    in
    match
      Keeper_exec_status_metrics.latest_tool_audit_snapshot_from_files config
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
  let fallback_latest_action_source =
    match file_snapshot with
    | Some snapshot -> (
        match snapshot.latest_action_source with
        | Some _ as value -> value
        | None -> fallback_action_source)
    | None -> fallback_action_source
  in
  let allowed_tool_names, latest_tool_names, latest_tool_call_count,
      latest_action_source, tool_audit_source, tool_audit_at =
    match A2a_tools.latest_heartbeat_task agent_name,
          A2a_tools.latest_heartbeat_result agent_name with
    | Some task, Some result ->
        if task.seq > result.seq then
          ( task.allowed_tools,
            result.tool_names,
            Some result.tool_call_count,
            fallback_latest_action_source,
            Some "heartbeat_task_pending_result",
            Some task.created_at )
        else
          ( task.allowed_tools,
            result.tool_names,
            Some result.tool_call_count,
            fallback_latest_action_source,
            Some "heartbeat_result",
            Some result.updated_at )
    | Some task, None ->
        ( task.allowed_tools,
          [],
          None,
          fallback_latest_action_source,
          Some "heartbeat_task",
          Some task.created_at )
    | None, Some result ->
        ( fallback_allowed,
          result.tool_names,
          Some result.tool_call_count,
          fallback_latest_action_source,
          Some "heartbeat_result",
          Some result.updated_at )
    | None, None ->
        (match file_snapshot with
        | Some snapshot ->
            ( fallback_allowed,
              snapshot.latest_tool_names,
              snapshot.latest_tool_call_count,
              snapshot.latest_action_source,
              snapshot.tool_audit_source,
              snapshot.tool_audit_at )
        | None ->
            (* Use per-keeper tool tracking as last-resort fallback *)
            let tracked = Keeper_tools_oas.tool_usage_for_keeper agent_name in
            if tracked <> [] then
              let names = List.map fst tracked in
              let total = List.fold_left (fun acc (_, e) -> acc + e.Keeper_tools_oas.count) 0 tracked in
              let latest_at = List.fold_left (fun acc (_, e) ->
                max acc e.Keeper_tools_oas.last_used_at) 0.0 tracked in
              let at_str = if latest_at > 0.0
                then Some (Dashboard_utils.iso_of_unix latest_at) else None in
              (fallback_allowed, names, Some total, None, Some "keeper_dispatch", at_str)
            else
              ( fallback_allowed,
                fallback_latest,
                fallback_count,
                fallback_action_source,
                fallback_source,
                fallback_at ))
  in
  [
    ("allowed_tool_names", string_list_json allowed_tool_names);
    ("latest_tool_names", string_list_json latest_tool_names);
    ( "latest_tool_call_count",
      option_to_json (fun value -> `Int value) latest_tool_call_count );
    ("latest_action_source", json_string_option latest_action_source);
    ("tool_audit_source", json_string_option tool_audit_source);
    ("tool_audit_at", json_string_option tool_audit_at);
  ]

let action_identity action =
  String.concat "|"
    [
      string_field "action_type" action;
      string_field "target_type" action;
      Option.value ~default:"none" (trim_to_option (string_field "target_id" action));
      normalized_text_key (string_field "reason" action);
    ]

let incident_identity incident =
  String.concat "|"
    [
      string_field "kind" incident;
      string_field "target_type" incident;
      Option.value ~default:"none" (trim_to_option (string_field "target_id" incident));
      normalized_text_key (string_field "summary" incident);
    ]

let identity_digest prefix identity =
  Printf.sprintf "%s:%s" prefix (Digest.to_hex (Digest.string identity))

let is_internal_attention incident =
  Operator_digest_types.is_root_alias (string_field "target_type" incident)

let is_internal_action action =
  Operator_digest_types.is_root_alias (string_field "target_type" action)

let incident_action_types kind =
  match kind with
  | "spawn_failure_present" -> [ "team_task_inject" ]
  | "detached_actor_present"
  | "empty_note_turn_present"
  | "low_confidence_routing"
  | "routing_escalation_present" -> [ "team_note" ]
  | "planned_worker_without_turn" -> [ "team_worker_spawn_batch"; "team_note" ]
  | "local64_role_gap" -> [ "team_worker_spawn_batch" ]
  | "stalled_session" -> [ "team_stop" ]
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
  let target_id = trim_to_option (string_field "target_id" incident) in
  let action_target_type = string_field "target_type" action in
  let action_target_id = trim_to_option (string_field "target_id" action) in
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

let build_keeper_briefs (config : Coord.config) (keepers : Yojson.Safe.t list) =
  let all_entries = Keeper_registry.all ~base_path:config.base_path () in
  let registry_lookup name =
    List.find_opt (fun (e : Keeper_registry.registry_entry) -> String.equal e.name name) all_entries
  in
  keepers
  |> List.filter_map (fun keeper ->
         let name = string_field "name" keeper in
         if name = "" then None
         else
           let status = string_field ~default:"unknown" "status" keeper in
           let context_ratio =
             match member_assoc "context_ratio" keeper with
             | `Float value -> Some value
             | `Int value -> Some (float_of_int value)
             | _ -> None
           in
           let pressure_rank =
             if Dashboard_utils.is_keeper_offline status then 3
             else if Option.value ~default:0.0 context_ratio >= lane_pressure_ctx_ratio then 2
             else if status = "idle" then 1
             else 0
           in
           Some
             {
               pressure_rank;
               last_seen_ts =
                 parse_iso_opt
                   (trim_to_option
                      (match trim_to_option (string_field "last_autonomous_action_at" keeper) with
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
                      ("context_ratio", option_to_json (fun value -> `Float value) context_ratio);
                      ("last_turn_ago_s", member_assoc "last_turn_ago_s" keeper);
                      ( "current_work",
                        json_string_option
                          (match trim_to_option (string_field "short_goal" keeper) with
                           | Some value -> Some value
                           | None -> trim_to_option (string_field "goal" keeper)) );
                      ("last_autonomous_action_at", member_assoc "last_autonomous_action_at" keeper);
                    ]
                    @ keeper_tool_audit_json_fields config registry_lookup keeper
                        (match trim_to_option (string_field "agent_name" keeper) with
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
                   ("action", option_to_json (fun value -> value) action);
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

let task_operation_status (task : Types.task) =
  match task.task_status with
  | Types.Todo | Types.Claimed _ | Types.InProgress _ -> Some "active"
  | Types.AwaitingVerification _ -> Some "paused"
  | Types.Done _ | Types.Cancelled _ -> None

let task_operation_updated_at (task : Types.task) =
  match task.task_status with
  | Types.Done { completed_at; _ } -> completed_at
  | Types.Cancelled { cancelled_at; _ } -> cancelled_at
  | Types.InProgress { started_at; _ } -> started_at
  | Types.AwaitingVerification { submitted_at; _ } -> submitted_at
  | Types.Claimed { claimed_at; _ } -> claimed_at
  | Types.Todo -> task.created_at

let task_operation_links (task : Types.task) =
  match task.contract with
  | Some contract -> contract.links
  | None -> { Types.operation_id = None; session_id = None; autoresearch_loop_id = None }

let task_operation_id (task : Types.task) =
  let links = task_operation_links task in
  match trim_to_option (Option.value ~default:"" links.operation_id) with
  | Some operation_id -> operation_id
  | None -> task.id

let build_operation_contexts ~(tasks : Types.task list) =
  tasks
  |> List.filter_map (fun (task : Types.task) ->
         match task_operation_status task with
         | None -> None
         | Some status ->
           let links = task_operation_links task in
           Some
             {
               operation_id = task_operation_id task;
               linked_session_id =
                 Option.bind links.session_id (fun value -> trim_to_option value);
               status = Some status;
               stage = Option.map Task_stage.to_string task.stage;
               detachment_status = None;
               objective = trim_to_option task.title;
               updated_at = Some (task_operation_updated_at task);
             })

let operation_badge_json (operation : operation_context) =
  let status_str =
    match operation.status with
    | Some s -> s
    | None -> "unknown"
  in
  let detachment_status_str =
    operation.detachment_status
  in
  `Assoc
    [
      ("operation_id", `String operation.operation_id);
      ("status", `String status_str);
      ("stage", json_string_option operation.stage);
      ("detachment_status", json_string_option detachment_status_str);
      ("objective", json_string_option operation.objective);
      ("updated_at", json_string_option operation.updated_at);
    ]

let operation_badges_for_session session operation_contexts =
  let linked_operation_ids =
    operation_contexts
    |> List.filter_map (fun (operation : operation_context) ->
           match operation.linked_session_id with
           | Some session_id when String.equal session_id session.session_id -> Some operation.operation_id
           | _ -> None)
  in
  let session_operation_ids =
    dedup_strings (Option.to_list session.operation_id @ linked_operation_ids)
  in
  let from_contexts =
    operation_contexts
    |> List.filter (fun (operation : operation_context) ->
           List.mem operation.operation_id session_operation_ids)
    |> List.map operation_badge_json
  in
  match from_contexts, session.operation_id with
  | [], Some operation_id ->
      [
        `Assoc
          [
            ("operation_id", `String operation_id);
            ("status", `String "unknown");
            ("stage", `Null);
            ("detachment_status", `Null);
            ("objective", `Null);
            ("updated_at", `Null);
          ];
      ]
  | _ -> from_contexts

let participant_preview_json session_id member_names agent_briefs =
  let member_set = List.sort_uniq String.compare member_names in
  agent_briefs
  |> List.filter_map (fun row ->
         let related_session_id = trim_to_option (string_field "related_session_id" row) in
         let agent_name = string_field "agent_name" row in
         let belongs =
           String.equal (Option.value ~default:"" related_session_id) session_id
           || List.mem agent_name member_set
         in
         if not belongs || agent_name = "" then None
         else
           Some
             (`Assoc
               [
                 ("agent_name", `String agent_name);
                 ("display_name", member_assoc "display_name" row);
                 ("is_live", member_assoc "is_live" row);
                 ("current_work", member_assoc "current_work" row);
                  ("recent_input_preview", member_assoc "recent_input_preview" row);
                  ("recent_output_preview", member_assoc "recent_output_preview" row);
                  ("last_activity_at", member_assoc "last_activity_at" row);
               ]))

let keeper_refs_for_session member_names keeper_briefs =
  let member_set = List.sort_uniq String.compare member_names in
  keeper_briefs
  |> List.filter_map (fun row ->
         let agent_name = trim_to_option (string_field "agent_name" row) in
         let name = string_field "name" row in
         let matches =
           (match agent_name with
           | Some value -> List.mem value member_set
           | None -> false)
           || List.mem name member_set
         in
         if not matches || name = "" then None
         else
           Some
             (`Assoc
               [
                 ("name", `String name);
                 ("agent_name", json_string_option agent_name);
                 ("status", member_assoc "status" row);
                 ("generation", member_assoc "generation" row);
                 ("context_ratio", member_assoc "context_ratio" row);
                 ("last_turn_ago_s", member_assoc "last_turn_ago_s" row);
                 ("current_work", member_assoc "current_work" row);
               ]))

let build_sessions ?(operation_contexts = []) sessions attention_queue agent_briefs keeper_briefs =
  let related_attention_count session_id =
    attention_queue
    |> List.fold_left
         (fun acc (attention : attention_context) ->
           if List.mem session_id attention.related_session_ids then acc + 1 else acc)
         0
  in
  sessions
  |> List.map (fun (session : session_context) ->
         let attention_count = related_attention_count session.session_id in
         let top_attention = option_to_json (fun value -> value) session.top_attention in
         let top_recommendation =
           option_to_json (fun value -> value) session.top_recommendation
         in
         ( attention_count,
           severity_rank
             (match session.top_attention with
             | Some attention ->
                 string_field
                   ~default:(Dashboard_utils.string_of_health_level session.health)
                   "severity" attention
             | None -> Dashboard_utils.string_of_health_level session.health),
           session.last_event_ts,
           `Assoc
             [
               ("session_id", `String session.session_id);
               ("goal", `String session.goal);
               ("created_by", json_string_option session.created_by);
               ("origin_kind", `String session.origin_kind);
               ("namespace", json_string_option session.namespace);
               ("status", `String (Dashboard_utils.string_of_session_lifecycle session.status));
               ("health", `String (Dashboard_utils.string_of_health_level session.health));
               ("member_names", string_list_json session.member_names);
               ("started_at", json_string_option session.started_at);
               ("elapsed_sec", option_to_json (fun value -> `Int value) session.elapsed_sec);
               ("operation_id", json_string_option session.operation_id);
               ("blocker_summary", json_string_option session.blocker_summary);
               ("last_event_at", json_string_option session.last_event_at);
               ("last_event_summary", `String session.last_event_summary);
               ("communication_summary", `String session.communication_summary);
               ("active_count", `Int session.active_count);
               ("seen_count", `Int session.seen_count);
               ("planned_count", `Int session.planned_count);
               ("required_count", `Int session.required_count);
               ("counts_basis", `String session.counts_basis);
               ("related_attention_count", `Int attention_count);
               ("top_attention", top_attention);
               ("top_recommendation", top_recommendation);
               ( "member_previews",
                 `List
                   (participant_preview_json session.session_id session.member_names agent_briefs)
               );
               ( "operation_badges",
                 `List (operation_badges_for_session session operation_contexts) );
               ( "keeper_refs",
                 `List (keeper_refs_for_session session.member_names keeper_briefs) );
             ] ))
  |> List.sort (fun (left_count, left_sev, left_ts, _) (right_count, right_sev, right_ts, _) ->
         let by_count = Int.compare right_count left_count in
         if by_count <> 0 then by_count
         else
           let by_severity = Int.compare right_sev left_sev in
           if by_severity <> 0 then by_severity else Float.compare right_ts left_ts)
  |> List.map (fun (_, _, _, json) -> json)

let session_timeline_json session_json =
  session_recent_events session_json
  |> List.sort (fun left right ->
         let right_ts =
           parse_iso_opt (trim_to_option (string_field "ts_iso" right))
           |> Option.value ~default:0.0
         in
         let left_ts =
           parse_iso_opt (trim_to_option (string_field "ts_iso" left))
           |> Option.value ~default:0.0
         in
         Float.compare right_ts left_ts)
  |> take 10
  |> List.mapi (fun idx event_json ->
         let detail = event_detail_json event_json in
         `Assoc
           [
             ("id", `String (Printf.sprintf "event-%d" idx));
             ("timestamp", member_assoc "ts_iso" event_json);
             ("event_type", member_assoc "event_type" event_json);
             ( "actor",
               json_string_option
                 (match trim_to_option (string_field "actor" detail) with
                 | Some value -> Some value
                 | None -> trim_to_option (string_field "agent" detail)) );
             ("summary", `String (event_summary event_json));
           ])
