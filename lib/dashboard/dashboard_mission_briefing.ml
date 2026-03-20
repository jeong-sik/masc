let cache_ttl_sec = 300.0

let mission_briefing_surface_contract_json =
  `Assoc
    [
      ("summary", `String "narrative");
      ("sections", `String "narrative");
      ("basis", `String "truth");
    ]
type cache_state = {
  mutex : Eio.Mutex.t;
  mutable cached_at : float;
  mutable cached_json : Yojson.Safe.t option;
  mutable refresh_in_flight : bool;
  mutable last_error : string option;
}

let cache =
  {
    mutex = Eio.Mutex.create ();
    cached_at = 0.0;
    cached_json = None;
    refresh_in_flight = false;
    last_error = None;
  }

let with_cache_lock f =
  Eio.Mutex.use_rw ~protect:true cache.mutex f

let compact_text ?(max_len = 96) raw =
  let normalized =
    String.trim raw |> String.split_on_char '\n' |> String.concat " " |> String.trim
  in
  if normalized = "" then ""
  else if String.length normalized <= max_len then normalized
  else String.sub normalized 0 (max_len - 1) ^ "…"

let member_assoc key json =
  match json with
  | `Assoc fields -> (match List.assoc_opt key fields with Some value -> value | None -> `Null)
  | _ -> `Null

let string_field ?(default = "") key json =
  match member_assoc key json with
  | `String value -> value
  | _ -> default

let string_json ?(default = "unknown") ?(max_len = 96) json =
  match json with
  | `String value ->
      let compact = compact_text ~max_len value in
      if compact = "" then `String default else `String compact
  | _ -> `String default

let string_list_json json =
  match json with
  | `List items ->
      `List
        (items
        |> List.filter_map (function
             | `String value ->
                 let trimmed = String.trim value in
                 if trimmed = "" then None else Some (`String trimmed)
             | _ -> None))
  | _ -> `List []

let int_json ?(default = 0) json =
  match json with
  | `Int value -> `Int value
  | `Intlit raw -> (
      try `Int (int_of_string raw) with Failure _ -> `Int default)
  | `Float value -> `Int (int_of_float value)
  | _ -> `Int default

let float_json ?(default = 0.0) json =
  match json with
  | `Float value -> `Float value
  | `Int value -> `Float (float_of_int value)
  | `Intlit raw -> (
      try `Float (float_of_string raw) with Failure _ -> `Float default)
  | _ -> `Float default

let int_field ?(default = 0) key json =
  match member_assoc key json with
  | `Int value -> value
  | `Intlit raw -> (
      try int_of_string raw with Failure _ -> default)
  | `Float value -> int_of_float value
  | _ -> default

let rec take n = function
  | [] -> []
  | _ when n <= 0 -> []
  | x :: xs -> x :: take (n - 1) xs

let option_string_json = function
  | Some value when String.trim value <> "" -> `String (String.trim value)
  | _ -> `Null

let trim_to_option = function
  | Some text -> Dashboard_utils.trim_to_option text
  | None -> None

let mission_briefing_criteria =
  [
    "deterministic_rules_only";
    "no_model_status_inference";
    "communication_from_message_and_session_counts";
    "alignment_from_active_agents_and_focus_bindings";
    "watch_from_room_health_and_incident_counts";
    "metadata_gaps_reported_separately";
  ]

let criteria_json () =
  `List (List.map (fun item -> `String item) mission_briefing_criteria)

let parse_iso_opt = Dashboard_utils.parse_iso_opt

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

let relevant_sessions_for_briefing ~current_room ~now_ts sessions =
  let room_matches session_json =
    match trim_to_option (Some current_room) with
    | None -> true
    | Some room_id ->
        let status_detail = member_assoc "status" session_json in
        String.equal room_id
          (string_field "room_id" (member_assoc "session" status_detail))
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
      ("room_id", string_json ~default:"unknown-room" (member_assoc "room_id" session));
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

let compact_agent_json (agent : Types.agent) =
  let current_focus =
    match agent.current_task with
    | Some task when String.trim task <> "" -> compact_text ~max_len:120 task
    | _ -> "unassigned"
  in
  `Assoc
    [
      ("name", `String agent.name);
      ("agent_type", `String agent.agent_type);
      ("status", `String (Types.string_of_agent_status agent.status));
      ("assignment_status", `String (if current_focus = "unassigned" then "unassigned" else "assigned"));
      ("current_focus", `String current_focus);
      ("goal_hint", `String current_focus);
      ("joined_at", `String agent.joined_at);
      ("last_seen", `String agent.last_seen);
      ("capabilities", `List (List.map (fun item -> `String item) (take 2 agent.capabilities)));
    ]

let metadata_gap_json ~kind ~summary ~scope_type ~scope_id ~severity =
  `Assoc
    [
      ("kind", `String kind);
      ("summary", `String summary);
      ("scope_type", `String scope_type);
      ("scope_id", option_string_json scope_id);
      ("severity", `String severity);
    ]

let collect_metadata_gaps ~sessions ~keepers ~agents =
  let agent_needs_focus json =
    List.mem
      (String.lowercase_ascii (String.trim (string_field "status" json)))
      [ "active"; "busy" ]
  in
  let session_gaps =
    sessions
    |> List.concat_map (fun json ->
           let session_id = string_field "session_id" json |> fun value -> if value = "" then None else Some value in
           let items = ref [] in
           if string_field "goal" json = "unassigned" then
             items :=
               metadata_gap_json ~kind:"session_goal_missing"
                 ~summary:"Session goal is unassigned in briefing facts."
                 ~scope_type:"session" ~scope_id:session_id ~severity:"watch"
               :: !items;
           if string_field "communication_mode" json = "unknown" then
             items :=
               metadata_gap_json ~kind:"session_communication_mode_missing"
                 ~summary:"Session communication mode is not recorded."
                 ~scope_type:"session" ~scope_id:session_id ~severity:"watch"
               :: !items;
           List.rev !items)
  in
  let keeper_gaps =
    keepers
    |> List.filter_map (fun json ->
           let status = string_field "last_reply_status" json in
           if status = "not_recorded" then
             Some
               (metadata_gap_json ~kind:"keeper_last_reply_missing"
                  ~summary:"Keeper last reply status is not recorded."
                  ~scope_type:"keeper"
                  ~scope_id:(Some (string_field "name" json))
                  ~severity:"info")
           else None)
  in
  let agent_gaps =
    agents
    |> List.filter_map (fun json ->
           if string_field "assignment_status" json = "unassigned"
              && agent_needs_focus json
           then
             Some
               (metadata_gap_json ~kind:"agent_focus_missing"
                  ~summary:"Active agent has no current focus bound."
                  ~scope_type:"agent"
                  ~scope_id:(Some (string_field "name" json))
                  ~severity:"watch")
           else None)
  in
  take 8 (session_gaps @ keeper_gaps @ agent_gaps)

let gap_kinds_for_section = function
  | "communication" ->
      [ "session_communication_mode_missing"; "keeper_last_reply_missing" ]
  | "alignment" ->
      [ "session_goal_missing"; "agent_focus_missing" ]
  | _ -> []

let count_metadata_gaps_for_section ~section_id gaps =
  let allowed = gap_kinds_for_section section_id in
  gaps
  |> List.fold_left
       (fun acc json ->
         let kind = string_field "kind" json in
         if List.mem kind allowed then acc + 1 else acc)
       0

let has_operational_signal ~section_id ~room_health ~incident_count ~recommended_action_count =
  let room_risky =
    List.mem (String.lowercase_ascii (String.trim room_health)) [ "bad"; "risk"; "critical" ]
  in
  match section_id with
  | "watch" -> room_risky || incident_count > 0 || recommended_action_count > 0
  | "communication" | "alignment" -> room_risky || incident_count > 0
  | _ -> false

let annotate_section ~section_id ~status ~summary ~evidence ~metadata_gaps
    ~room_health ~incident_count ~recommended_action_count =
  let gap_count = count_metadata_gaps_for_section ~section_id metadata_gaps in
  let operational =
    has_operational_signal ~section_id ~room_health ~incident_count
      ~recommended_action_count
  in
  let signal_class, evidence_quality =
    if gap_count > 0 && not operational then
      ("metadata_gap", "missing")
    else if gap_count > 0 && operational then
      ("mixed", "partial")
    else if operational && evidence <> [] then
      ("operational_risk", "strong")
    else if operational then
      ("operational_risk", "partial")
    else if evidence <> [] then
      ("operational_risk", "partial")
    else
      ("operational_risk", "missing")
  in
  `Assoc
    [
      ("id", `String section_id);
      ("label", `String (match section_id with "communication" -> "Communication" | "alignment" -> "Alignment" | _ -> "Watch Next"));
      ("status", `String status);
      ("summary", `String summary);
      ("evidence", `List (List.map (fun item -> `String item) evidence));
      ("signal_class", `String signal_class);
      ("evidence_quality", `String evidence_quality);
      ("provenance", `String "narrative");
      ("authoritative", `Bool false);
    ]

let int_field_direct ?(default = 0) key json = int_field ~default key json

let sum_int_field key items =
  List.fold_left (fun acc json -> acc + int_field_direct key json) 0 items

let count_matching_field key ~predicate items =
  List.fold_left
    (fun acc json -> if predicate (string_field key json) then acc + 1 else acc)
    0 items

let status_is_active_agent value =
  List.mem
    (String.lowercase_ascii (String.trim value))
    [ "active"; "busy" ]

let evidence_of_metadata_gaps ~section_id metadata_gaps =
  let allowed = gap_kinds_for_section section_id in
  metadata_gaps
  |> List.filter_map (fun json ->
         let kind = string_field "kind" json in
         if List.mem kind allowed then Some (string_field "summary" json) else None)
  |> take 2

let evidence_add_if cond text items =
  if cond && text <> "" then text :: items else items

let build_communication_section ~sessions ~recent_messages ~metadata_gaps
    ~room_health ~incident_count ~recommended_action_count =
  let live_session_count = List.length sessions in
  let recent_message_count = List.length recent_messages in
  let broadcast_total = sum_int_field "broadcast_count" sessions in
  let portal_total = sum_int_field "portal_count" sessions in
  let known_mode_count =
    count_matching_field "communication_mode" sessions ~predicate:(fun value ->
        value <> "" && value <> "unknown")
  in
  let metadata_evidence =
    evidence_of_metadata_gaps ~section_id:"communication" metadata_gaps
  in
  let positive_signal =
    recent_message_count > 0 || broadcast_total > 0 || portal_total > 0
  in
  let positive_evidence =
    []
    |> evidence_add_if (recent_message_count > 0)
         (Printf.sprintf "Recent room messages recorded: %d" recent_message_count)
    |> evidence_add_if (broadcast_total > 0)
         (Printf.sprintf "Session broadcasts recorded: %d" broadcast_total)
    |> evidence_add_if (portal_total > 0)
         (Printf.sprintf "Portal messages recorded: %d" portal_total)
  in
  let inactivity_evidence =
    []
    |> evidence_add_if
         (not positive_signal && live_session_count = 0)
         "Active sessions count is zero"
    |> evidence_add_if
         (not positive_signal && live_session_count > 0)
         "No communication activity is recorded for the live sessions"
  in
  let evidence =
    if metadata_evidence <> [] then
      take 2 (metadata_evidence @ positive_evidence @ inactivity_evidence)
    else
      take 2 (positive_evidence @ inactivity_evidence)
  in
  if positive_signal && metadata_evidence = [] then
    ("healthy", "Communication activity is recorded across recent messages and session metrics.", evidence)
  else if positive_signal then
    ("watch", "Communication activity exists, but some communication metadata is still missing.", evidence)
  else if live_session_count = 0 then
    ("unclear", "No live session is present, so communication health cannot be judged.", evidence)
  else if metadata_evidence <> [] then
    ("unclear", "Communication metadata is incomplete and no positive activity signal is recorded.", evidence)
  else if known_mode_count = 0 then
    ("unclear", "Communication mode is not recorded for the live sessions.", evidence)
  else if List.mem (String.lowercase_ascii (String.trim room_health)) [ "bad"; "risk"; "critical" ]
          || incident_count > 0 || recommended_action_count > 0
  then
    ("watch", "Live sessions exist without recorded communication activity while the room still has open operator attention.", evidence)
  else
    ("watch", "Live sessions exist, but no communication activity is recorded yet.", evidence)

let build_alignment_section ~sessions ~agents ~metadata_gaps =
  let active_agent_count =
    List.fold_left
      (fun acc json ->
        if status_is_active_agent (string_field "status" json) then acc + 1 else acc)
      0 agents
  in
  let assigned_active_agent_count =
    List.fold_left
      (fun acc json ->
        if status_is_active_agent (string_field "status" json)
           && String.equal (string_field "assignment_status" json) "assigned"
        then acc + 1
        else acc)
      0 agents
  in
  let bound_goal_count =
    List.fold_left
      (fun acc json ->
        if String.equal (string_field "goal" json) "unassigned" then acc else acc + 1)
      0 sessions
  in
  let metadata_evidence =
    evidence_of_metadata_gaps ~section_id:"alignment" metadata_gaps
  in
  let evidence =
    []
    |> evidence_add_if (active_agent_count = 0) "Active agents count is zero"
    |> evidence_add_if (active_agent_count > 0)
         (Printf.sprintf "Active agents recorded: %d" active_agent_count)
    |> evidence_add_if (bound_goal_count > 0)
         (Printf.sprintf "Session goals bound: %d" bound_goal_count)
    |> evidence_add_if
         (active_agent_count > 0 && assigned_active_agent_count = active_agent_count)
         "All active agents have bound focus"
    |> fun items -> items @ metadata_evidence
    |> take 2
  in
  if active_agent_count = 0 then
    ("unclear", "No active agents are present, so alignment cannot be judged.", evidence)
  else if metadata_evidence <> [] then
    ("unclear", "Goal or focus bindings are incomplete, so alignment cannot be confirmed.", evidence)
  else if bound_goal_count = 0 then
    ("unclear", "Active agents exist, but no bound session goal is recorded.", evidence)
  else if assigned_active_agent_count = active_agent_count then
    ("aligned", "Active agents have bound focus and session goals are recorded.", evidence)
  else
    ("watch", "Some active agents are present without a bound focus.", evidence)

let build_watch_section ~room_health ~incident_count ~recommended_action_count
    ~top_attention_summary =
  let lowered_room_health = String.lowercase_ascii (String.trim room_health) in
  let risky_room =
    List.mem lowered_room_health [ "bad"; "risk"; "critical" ]
  in
  let evidence =
    []
    |> evidence_add_if risky_room (Printf.sprintf "Room health is %s" room_health)
    |> evidence_add_if (incident_count > 0)
         (Printf.sprintf "Incident count is %d" incident_count)
    |> evidence_add_if (recommended_action_count > 0)
         (Printf.sprintf "Recommended actions count is %d" recommended_action_count)
    |> evidence_add_if
         (top_attention_summary <> "" && top_attention_summary <> "unknown")
         top_attention_summary
    |> take 2
  in
  if risky_room then
    ( "risk",
      Printf.sprintf
        "Room health is %s with %d incidents and %d recommended actions."
        room_health incident_count recommended_action_count,
      evidence )
  else if incident_count > 0 || recommended_action_count > 0 then
    ( "watch",
      Printf.sprintf
        "Operator attention remains open with %d incidents and %d recommended actions."
        incident_count recommended_action_count,
      evidence )
  else
    ("ok", "No immediate operator action is flagged by the room summary.", evidence)

let build_briefing_sections ~mission_summary_json ~sessions ~agents ~recent_messages
    ~metadata_gaps =
  let room_health = mission_summary_json |> string_field "room_health" in
  let incident_count = mission_summary_json |> int_field "incident_count" in
  let recommended_action_count =
    mission_summary_json |> int_field "recommended_action_count"
  in
  let top_attention_summary =
    mission_summary_json |> string_field "top_attention_summary"
  in
  let communication_status, communication_summary, communication_evidence =
    build_communication_section ~sessions ~recent_messages ~metadata_gaps
      ~room_health ~incident_count ~recommended_action_count
  in
  let alignment_status, alignment_summary, alignment_evidence =
    build_alignment_section ~sessions ~agents ~metadata_gaps
  in
  let watch_status, watch_summary, watch_evidence =
    build_watch_section ~room_health ~incident_count ~recommended_action_count
      ~top_attention_summary
  in
  ( watch_summary,
    [
      annotate_section ~section_id:"communication" ~status:communication_status
        ~summary:communication_summary ~evidence:communication_evidence
        ~metadata_gaps ~room_health ~incident_count ~recommended_action_count;
      annotate_section ~section_id:"alignment" ~status:alignment_status
        ~summary:alignment_summary ~evidence:alignment_evidence ~metadata_gaps
        ~room_health ~incident_count ~recommended_action_count;
      annotate_section ~section_id:"watch" ~status:watch_status
        ~summary:watch_summary ~evidence:watch_evidence ~metadata_gaps
        ~room_health ~incident_count ~recommended_action_count;
    ] )

module For_test = struct
  let compact_session_json = compact_session_json
  let compact_keeper_json = compact_keeper_json
  let compact_agent_json = compact_agent_json
  let relevant_sessions_for_briefing = relevant_sessions_for_briefing
  let collect_metadata_gaps = collect_metadata_gaps
  let build_briefing_sections = build_briefing_sections
  let reset_cache () =
    with_cache_lock (fun () ->
        cache.cached_at <- 0.0;
        cache.cached_json <- None;
        cache.refresh_in_flight <- false;
        cache.last_error <- None)
  let seed_cache ?(cached_at = 0.0) ?last_error ?(refresh_in_flight = false) json =
    with_cache_lock (fun () ->
        cache.cached_at <- cached_at;
        cache.cached_json <- Some json;
        cache.refresh_in_flight <- refresh_in_flight;
        cache.last_error <- last_error)
end

let error_json ~now ~reason =
  `Assoc
    [
      ("generated_at", `String now);
      ("cached", `Bool false);
      ("stale", `Bool false);
      ("refreshing", `Bool false);
      ("status", `String "error");
      ("summary", `String "Mission briefing refresh failed. Retry to request a fresh judgment.");
      ("provenance", `String "narrative");
      ("authoritative", `Bool false);
      ("provenance_summary", mission_briefing_surface_contract_json);
      ("model", `Null);
      ("ttl_sec", `Int (int_of_float cache_ttl_sec));
      ("criteria", criteria_json ());
      ("sections", `List []);
      ("error", `String reason);
      ("last_error", option_string_json (Some reason));
    ]

let pending_json ~now ~last_error =
  `Assoc
    [
      ("generated_at", `String now);
      ("cached", `Bool false);
      ("stale", `Bool false);
      ("refreshing", `Bool true);
      ("status", `String "pending");
      ("summary", `String "Generating mission briefing from the latest snapshot.");
      ("provenance", `String "narrative");
      ("authoritative", `Bool false);
      ("provenance_summary", mission_briefing_surface_contract_json);
      ("model", `Null);
      ("ttl_sec", `Int (int_of_float cache_ttl_sec));
      ("criteria", criteria_json ());
      ("sections", `List []);
      ("error", `Null);
      ("last_error", option_string_json last_error);
    ]
let with_cached_flag cached json =
  match json with
  | `Assoc fields ->
      `Assoc (("cached", `Bool cached) :: List.remove_assoc "cached" fields)
  | other -> other

let upsert_field key value json =
  match json with
  | `Assoc fields -> `Assoc ((key, value) :: List.remove_assoc key fields)
  | other -> other

let annotate_delivery_state json ~cached ~stale ~refreshing ~last_error =
  json
  |> with_cached_flag cached
  |> upsert_field "stale" (`Bool stale)
  |> upsert_field "refreshing" (`Bool refreshing)
  |> upsert_field "last_error" (option_string_json last_error)

let compute_briefing_json ~actor_name ~config ~sw ~clock ~proc_mgr () =
  let now_ts = Unix.gettimeofday () in
    let mission_json =
      Dashboard_mission.json ~actor:actor_name ~config ~sw ~clock ~proc_mgr ()
    in
    let ctx : _ Operator_control.context =
      {
        config;
        agent_name = actor_name;
        sw;
        clock;
        proc_mgr;
        mcp_session_id = None;
      }
    in
    let snapshot_json =
      Operator_control.snapshot_json ~actor:actor_name ~view:"summary"
        ~include_messages:true ~include_sessions:true ~include_keepers:true ctx
    in
    let sessions =
      match snapshot_json |> member_assoc "sessions" |> member_assoc "items" with
      | `List items -> items
      | _ -> []
    in
    let current_room = snapshot_json |> member_assoc "room" |> string_field "current_room" in
    let sessions =
      relevant_sessions_for_briefing ~current_room ~now_ts sessions
    in
    let keepers =
      match snapshot_json |> member_assoc "keepers" |> member_assoc "items" with
      | `List items -> items
      | _ -> []
    in
    let compact_sessions = take 3 (List.map compact_session_json sessions) in
    let compact_keepers = take 3 (List.map compact_keeper_json keepers) in
    let agents_json = Room.get_agents_raw config |> List.map compact_agent_json in
    let compact_agents = take 5 agents_json in
    let messages_json =
      Room.get_messages_raw config ~since_seq:0 ~limit:4
      |> List.map (fun (message : Types.message) ->
             `Assoc
               [
                 ("from", `String message.from_agent);
                 ("content", `String (compact_text ~max_len:72 message.content));
                 ("timestamp", `String message.timestamp);
               ])
    in
    let mission_summary_json =
      let summary = member_assoc "summary" mission_json in
      `Assoc
        [
          ("room_health", member_assoc "room_health" summary);
          ("current_room", member_assoc "current_room" summary);
          ("active_agents", member_assoc "active_agents" summary);
          ("keeper_pressure", member_assoc "keeper_pressure" summary);
          ("active_operations", member_assoc "active_operations" summary);
          ("incident_count", member_assoc "incident_count" summary);
          ("recommended_action_count", member_assoc "recommended_action_count" summary);
          ( "top_attention_summary",
            match member_assoc "top_attention" summary |> member_assoc "summary" with
            | `String value -> `String (compact_text value)
            | other -> other );
        ]
    in
    let metadata_gaps =
      collect_metadata_gaps ~sessions:compact_sessions ~keepers:compact_keepers
        ~agents:compact_agents
    in
    let watch_summary, sections =
      build_briefing_sections ~mission_summary_json ~sessions:compact_sessions
        ~agents:compact_agents ~recent_messages:messages_json ~metadata_gaps
    in
    let now_iso = Types.now_iso () in
    Ok
      (`Assoc
        [
          ("generated_at", `String now_iso);
          ("cached", `Bool false);
          ("stale", `Bool false);
          ("refreshing", `Bool false);
          ("status", `String "ok");
          ("summary", `String watch_summary);
          ("provenance", `String "narrative");
          ("authoritative", `Bool false);
          ("provenance_summary", mission_briefing_surface_contract_json);
          ("model", `String "deterministic");
          ("ttl_sec", `Int (int_of_float cache_ttl_sec));
          ("criteria", criteria_json ());
          ("metadata_gap_count", `Int (List.length metadata_gaps));
          ("metadata_gaps", `List metadata_gaps);
          ( "basis",
            `Assoc
              [
                ( "current_room",
                  member_assoc "summary" mission_json
                  |> member_assoc "current_room" );
                ("crew_count", `Int (List.length sessions));
                ("agent_count", `Int (List.length agents_json));
                ("keeper_count", `Int (List.length keepers));
              ] );
          ("sections", `List sections);
          ("error", `Null);
          ("last_error", `Null);
        ])

let start_async_refresh ~actor_name ~config ~sw ~clock ~proc_mgr () =
  let should_start =
    with_cache_lock (fun () ->
        if cache.refresh_in_flight then
          false
        else (
          cache.refresh_in_flight <- true;
          true))
  in
  let refresh_sw =
    match Eio_context.get_switch_opt () with
    | Some server_sw -> server_sw
    | None -> sw
  in
  if should_start then
    Eio.Fiber.fork_daemon ~sw:refresh_sw (fun () ->
        (try
           match
             compute_briefing_json ~actor_name ~config ~sw:refresh_sw ~clock
               ~proc_mgr ()
           with
           | Ok result_json ->
               with_cache_lock (fun () ->
                   cache.cached_json <- Some result_json;
                   cache.cached_at <- Unix.gettimeofday ();
                   cache.refresh_in_flight <- false;
                   cache.last_error <- None)
           | Error reason ->
               with_cache_lock (fun () ->
                   cache.refresh_in_flight <- false;
                   cache.last_error <- Some reason)
         with exn ->
           with_cache_lock (fun () ->
               cache.refresh_in_flight <- false;
               cache.last_error <- Some (Printexc.to_string exn)));
        `Stop_daemon)

let actor_name = function
  | Some value when String.trim value <> "" -> String.trim value
  | _ -> "dashboard"

let json ?actor ?(force = false) ~config ~sw ~clock ~proc_mgr () =
  let now_ts = Unix.gettimeofday () in
  let now_iso = Types.now_iso () in
  let actor_name = actor_name actor in
  let cached_json, is_fresh, refresh_in_flight, last_error =
    with_cache_lock (fun () ->
        let cached_json = cache.cached_json in
        let is_fresh =
          match cached_json with
          | Some _ -> now_ts -. cache.cached_at < cache_ttl_sec
          | None -> false
        in
        (cached_json, is_fresh, cache.refresh_in_flight, cache.last_error))
  in
  match cached_json with
  | Some cached_json ->
      if not force && is_fresh then
        annotate_delivery_state cached_json ~cached:true ~stale:false
          ~refreshing:refresh_in_flight ~last_error
      else (
        if not refresh_in_flight then
          start_async_refresh ~actor_name ~config ~sw ~clock ~proc_mgr ();
        annotate_delivery_state cached_json ~cached:true ~stale:true
          ~refreshing:true ~last_error)
  | None ->
      if force then (
        if not refresh_in_flight then
          start_async_refresh ~actor_name ~config ~sw ~clock ~proc_mgr ();
        pending_json ~now:now_iso ~last_error)
      else
        match compute_briefing_json ~actor_name ~config ~sw ~clock ~proc_mgr () with
        | Ok result_json ->
            with_cache_lock (fun () ->
                cache.cached_json <- Some result_json;
                cache.cached_at <- Unix.gettimeofday ();
                cache.last_error <- None);
            result_json
        | Error reason ->
            with_cache_lock (fun () -> cache.last_error <- Some reason);
            error_json ~now:now_iso ~reason
