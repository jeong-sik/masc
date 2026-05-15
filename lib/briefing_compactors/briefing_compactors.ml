(** Compact raw domain JSON into briefing-ready form. *)

open Briefing_json_helpers

let status_is_live value =
  List.mem
    (String.lowercase_ascii (String.trim value))
    [ "running"; "active"; "paused"; "starting"; "stopping"; "waiting" ]

let event_timestamp json =
  parse_iso_opt (trim_to_option (Some (string_field "ts_iso" json)))

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
  let room_matches session_json =
    match trim_to_option (Some current_namespace) with
    | None -> true
    | Some project ->
        let status_detail = member_assoc "status" session_json in
        let session_json = member_assoc "session" status_detail in
        let session_project =
          match trim_to_option (Some (string_field "project" session_json)) with
          | Some value -> value
          | None ->
              trim_to_option (Some (string_field "room_id" session_json))
              |> Option.value ~default:""
        in
        String.equal project session_project
  in
  sessions
  |> List.filter (fun session_json ->
         room_matches session_json
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
            ("event_type", string_json ~default:"unknown" (member_assoc "event_type" latest));
            ("ts_iso", string_json ~default:"unknown" (member_assoc "ts_iso" latest));
            ("actor", string_json ~default:"unknown" (member_assoc "actor" detail));
            ("task_title", string_json ~default:"not_recorded" (member_assoc "task_title" detail));
            ("result", string_json ~default:"not_recorded" ~max_len:160 (member_assoc "result" detail));
            ("reason", string_json ~default:"not_recorded" ~max_len:160 (member_assoc "reason" detail));
          ]
    | [] ->
        `Assoc
          [
            ("event_type", `String "none");
            ("ts_iso", `String "unknown");
            ("actor", `String "unknown");
            ("task_title", `String "no recent session events");
            ("result", `String "not_recorded");
            ("reason", `String "not_recorded");
          ]
  in
  let communication_mode =
    string_json ~default:"unknown" (member_assoc "mode" communication)
  in
  let broadcast_count = int_json (member_assoc "broadcast_count" communication) in
  let portal_count = int_json (member_assoc "portal_count" communication) in
  let communication_mode_text =
    match communication_mode with
    | `String value -> value
    | _ -> "unknown"
  in
  let broadcast_count_value =
    match broadcast_count with
    | `Int value -> value
    | _ -> 0
  in
  let portal_count_value =
    match portal_count with
    | `Int value -> value
    | _ -> 0
  in
  `Assoc
    [
      ("session_id", string_json ~default:"unknown-session" (member_assoc "session_id" session_json));
      ("goal", string_json ~default:"unassigned" ~max_len:160 (member_assoc "goal" session));
      ( "project",
        match member_assoc "project" session with
        | `Null -> string_json ~default:"default" (member_assoc "room_id" session)
        | value -> string_json ~default:"default" value );
      ("status", string_json ~default:"unknown" (member_assoc "status" session));
      ("agent_names", string_list_json (member_assoc "agent_names" session));
      ("elapsed_sec", int_json (member_assoc "elapsed_sec" summary));
      ("progress_pct", float_json (member_assoc "progress_pct" summary));
      ("done_delta_total", int_json (member_assoc "done_delta_total" summary));
      ("team_health", string_json ~default:"unknown" (member_assoc "status" team_health));
      ("active_agents_count", int_json (member_assoc "active_agents_count" team_health));
      ("required_agents", int_json ~default:1 (member_assoc "required_agents" team_health));
      ("communication_mode", communication_mode);
      ("broadcast_count", broadcast_count);
      ("portal_count", portal_count);
      ( "communication_summary",
        `String
          (Printf.sprintf "%s · broadcast %d · portal %d"
             communication_mode_text broadcast_count_value portal_count_value) );
      ("last_event", last_event);
    ]

let compact_keeper_json keeper_json =
  let diagnostic = member_assoc "diagnostic" keeper_json in
  let agent = member_assoc "agent" keeper_json in
  `Assoc
    [
      ("name", string_json ~default:"unknown-keeper" (member_assoc "name" keeper_json));
      ("status", string_json ~default:"unknown" (member_assoc "status" keeper_json));
      ("agent_name", string_json ~default:"unknown" (member_assoc "agent_name" keeper_json));
      ("generation", int_json (member_assoc "generation" keeper_json));
      ("context_ratio", float_json (member_assoc "context_ratio" keeper_json));
      ("last_turn_ago_s", float_json (member_assoc "last_turn_ago_s" keeper_json));
      ("compaction_count", int_json (member_assoc "compaction_count" keeper_json));
      ("handoff_count_total", int_json (member_assoc "handoff_count_total" keeper_json));
      ("current_task", string_json ~default:"unassigned" ~max_len:160 (member_assoc "current_task" agent));
      ("last_reply_status", string_json ~default:"not_recorded" (member_assoc "last_reply_status" diagnostic));
      ("last_reply_preview", string_json ~default:"not_recorded" ~max_len:160 (member_assoc "last_reply_preview" diagnostic));
      ("active_goal_ids", string_list_json (member_assoc "active_goal_ids" keeper_json));
      ("skill_primary", string_json ~default:"unknown" ~max_len:120 (member_assoc "skill_primary" keeper_json));
    ]

let compact_agent_json (agent : Masc_domain.agent) =
  let current_focus =
    match agent.current_task with
    | Some task when String.trim task <> "" -> compact_text ~max_len:120 task
    | _ -> "unassigned"
  in
  `Assoc
    [
      ("name", `String agent.name);
      ("agent_type", `String agent.agent_type);
      ("status", `String (Masc_domain.string_of_agent_status agent.status));
      ("assignment_status", `String (if current_focus = "unassigned" then "unassigned" else "assigned"));
      ("current_focus", `String current_focus);
      ("goal_hint", `String current_focus);
      ("joined_at", `String agent.joined_at);
      ("last_seen", `String agent.last_seen);
      ("capabilities", `List (List.map (fun item -> `String item) (take 2 agent.capabilities)));
    ]
