(** Compact raw domain JSON into briefing-ready form. *)

open Briefing_json_helpers

let status_is_live value =
  List.mem
    (String.lowercase_ascii (String.trim value))
    [ "running"; "active"; "paused"; "starting"; "stopping"; "waiting" ]

let event_timestamp json =
  Dashboard_utils.parse_iso_opt (String_util.option_trim (Some (string_field "ts_iso" json)))

let session_recent_enough ~now_ts session_json =
  let recent_events =
    match member_assoc "recent_events" session_json with
    | `List items -> items
    | _ -> []
  in
  recent_events
  |> List.filter_map event_timestamp
  |> List.sort Float.compare
  |> List.rev
  |> function
  | latest :: _ -> now_ts -. latest <= 3600.0
  | [] -> false

let relevant_sessions_for_briefing ~current_namespace ~now_ts sessions =
  let workspace_matches session_json =
    match String_util.option_trim (Some current_namespace) with
    | None -> true
    | Some project ->
        let status_detail = member_assoc "status" session_json in
        let session_json = member_assoc "session" status_detail in
        let session_project =
          match String_util.option_trim (Some (string_field "project" session_json)) with
          | Some value -> value
          | None ->
              String_util.option_trim (Some (string_field "workspace_id" session_json))
              |> Option.value ~default:""
        in
        String.equal project session_project
  in
  sessions
  |> List.filter (fun session_json ->
         workspace_matches session_json
         &&
         let status_detail = member_assoc "status" session_json in
         let status =
           string_field "status" (member_assoc "summary" status_detail)
           |> fun value ->
           if String.trim value <> "" then value
           else string_field "status" (member_assoc "session" status_detail)
         in
         status_is_live status || session_recent_enough ~now_ts session_json)

let compact_session_json session_json =
  let status_detail = member_assoc "status" session_json in
  let session = member_assoc "session" status_detail in
  let summary = member_assoc "summary" status_detail in
  let team_health = member_assoc "team_health" status_detail in
  let communication = member_assoc "communication_metrics" status_detail in
  let recent_events =
    match member_assoc "recent_events" session_json with
    | `List items -> items
    | _ -> []
  in
  let last_event =
    match List.rev recent_events with
    | latest :: _ ->
        let detail = member_assoc "detail" latest in
        `Assoc
          [
            ("event_type", string_json_opt (member_assoc "event_type" latest));
            ("ts_iso", string_json_opt (member_assoc "ts_iso" latest));
            ("actor", string_json_opt (member_assoc "actor" detail));
            ("task_title", string_json_opt (member_assoc "task_title" detail));
            ("result", string_json_opt ~max_len:160 (member_assoc "result" detail));
            ("reason", string_json_opt ~max_len:160 (member_assoc "reason" detail));
          ]
    | [] -> `Null
  in
  let communication_mode =
    string_json_opt (member_assoc "mode" communication)
  in
  let broadcast_count = int_json (member_assoc "broadcast_count" communication) in
  let communication_summary =
    match communication_mode with
    | `String value -> Printf.sprintf "%s · broadcast %d" value
    | _ -> Printf.sprintf "broadcast %d"
  in
  let broadcast_count_value =
    match broadcast_count with
    | `Int value -> value
    | _ -> 0
  in
  `Assoc
    [
      ("session_id", string_json_opt (member_assoc "session_id" session_json));
      ("goal", string_json_opt ~max_len:160 (member_assoc "goal" session));
      ( "project",
        match member_assoc "project" session with
        | `Null -> string_json_opt (member_assoc "workspace_id" session)
        | value -> string_json_opt value );
      ("status", string_json_opt (member_assoc "status" session));
      ("agent_names", string_list_json (member_assoc "agent_names" session));
      ("elapsed_sec", int_json (member_assoc "elapsed_sec" summary));
      ("progress_pct", float_json (member_assoc "progress_pct" summary));
      ("done_delta_total", int_json (member_assoc "done_delta_total" summary));
      ("team_health", string_json_opt (member_assoc "status" team_health));
      ("active_agents_count", int_json (member_assoc "active_agents_count" team_health));
      ("required_agents", int_json ~default:1 (member_assoc "required_agents" team_health));
      ("communication_mode", communication_mode);
      ("broadcast_count", broadcast_count);
      ( "communication_summary",
        `String (communication_summary broadcast_count_value) );
      ("last_event", last_event);
    ]

let compact_keeper_json keeper_json =
  let diagnostic = member_assoc "diagnostic" keeper_json in
  let agent = member_assoc "agent" keeper_json in
  `Assoc
    [
      ("name", string_json_opt (member_assoc "name" keeper_json));
      ("status", string_json_opt (member_assoc "status" keeper_json));
      ("agent_name", string_json_opt (member_assoc "agent_name" keeper_json));
      ("generation", int_json (member_assoc "generation" keeper_json));
      ("context_ratio", float_json (member_assoc "context_ratio" keeper_json));
      ("last_turn_ago_s", float_json (member_assoc "last_turn_ago_s" keeper_json));
      ("compaction_count", int_json (member_assoc "compaction_count" keeper_json));
      ("handoff_count_total", int_json (member_assoc "handoff_count_total" keeper_json));
      ("current_task", string_json_opt ~max_len:160 (member_assoc "current_task" agent));
      ("last_reply_status", string_json_opt (member_assoc "last_reply_status" diagnostic));
      ("last_reply_preview", string_json_opt ~max_len:160 (member_assoc "last_reply_preview" diagnostic));
    ]

let compact_agent_json (agent : Masc_domain.agent) =
  let current_focus =
    match agent.current_task with
    | Some task when String.trim task <> "" -> compact_text ~max_len:120 task
    | _ -> ""
  in
  let current_focus_json = Json_util.string_opt_to_json (String_util.trim_to_option current_focus) in
  `Assoc
    [
      ("name", `String agent.name);
      ("agent_type", `String agent.agent_type);
      ("status", `String (Masc_domain.string_of_agent_status agent.status));
      ("assignment_status", `String (if current_focus = "" then "unassigned" else "assigned"));
      ("current_focus", current_focus_json);
      ("goal_hint", current_focus_json);
      ("session_bound_at", `String agent.session_bound_at);
      ("last_seen", `String agent.last_seen);
      ("capabilities", `List (List.map (fun item -> `String item) (take 2 agent.capabilities)));
    ]
