let cache_ttl_sec = 300.0

let no_model_reason =
  "No dashboard briefing model is available in the current environment."

let briefing_timeout_sec () =
  match Sys.getenv_opt "MASC_DASHBOARD_BRIEFING_TIMEOUT_SEC" with
  | Some raw -> (
      try
        let value = int_of_string (String.trim raw) in
        max 3 value
      with Failure _ -> 20)
  | None -> 20

type cache_state = {
  mutex : Mutex.t;
  mutable cached_at : float;
  mutable cached_json : Yojson.Safe.t option;
  mutable refresh_in_flight : bool;
  mutable last_error : string option;
}

let cache =
  {
    mutex = Mutex.create ();
    cached_at = 0.0;
    cached_json = None;
    refresh_in_flight = false;
    last_error = None;
  }

let with_cache_lock f =
  Mutex.lock cache.mutex;
  Fun.protect f ~finally:(fun () -> Mutex.unlock cache.mutex)

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
  | Some value ->
      let trimmed = String.trim value in
      if trimmed = "" then None else Some trimmed
  | None -> None

let normalize_status raw ~allowed ~fallback =
  let lowered = String.trim raw |> String.lowercase_ascii in
  if List.mem lowered allowed then lowered else fallback

let split_csv_nonempty raw =
  raw
  |> String.split_on_char ','
  |> List.filter_map (fun item ->
         let trimmed = String.trim item in
         if trimmed = "" then None else Some trimmed)

(** Model specs for mission briefing LLM cascade.
    Explicit MASC_DASHBOARD_BRIEFING_MODELS keeps its old escape-hatch behavior.
    Otherwise delegate to Lodge_cascade for hot-reloadable config/defaults. *)
let mission_briefing_models () =
  match Sys.getenv_opt "MASC_DASHBOARD_BRIEFING_MODELS" with
  | Some raw ->
      let parsed = split_csv_nonempty raw in
      if parsed = [] then
        Lodge_cascade.get_cascade ~cascade_name:"briefing" ()
      else
        Llm_client.available_model_specs_of_strings parsed
  | None ->
      Lodge_cascade.get_cascade ~cascade_name:"briefing" ()

let mission_briefing_criteria =
  [
    "facts_only";
    "communication_from_recent_messages_and_session_events";
    "alignment_from_goal_task_output_consistency";
    "use_unclear_when_evidence_is_thin";
    "hide_raw_chain_of_thought";
  ]

let criteria_json () =
  `List (List.map (fun item -> `String item) mission_briefing_criteria)

let prompt_for_facts (facts_json : Yojson.Safe.t) =
  Printf.sprintf
    "You are preparing a human-facing operator briefing for a swarm dashboard.\n\
     Use only the factual snapshot below.\n\
     Never invent facts. If evidence is insufficient, use \"unclear\".\n\
     Treat placeholders such as \"unknown\", \"unassigned\", \"not_recorded\", empty lists, and zero communication counters as missing metadata, not direct evidence of risk.\n\
     Do not call something risky only because a field is missing.\n\
     Only escalate communication or alignment to watch/risk when corroborating evidence appears in incidents, room health, recent events, or contradictory task focus.\n\
     Judge whether communication looks healthy and whether work appears aligned to the same goal.\n\
     Keep summaries short. Each summary should be one sentence, optimized for a top-level dashboard card.\n\
     Keep each evidence list to at most 2 short strings.\n\
     Output strict JSON only with this shape:\n\
     {\n\
       \"communication_status\": \"healthy|watch|risk|unclear\",\n\
       \"communication_summary\": string,\n\
       \"alignment_status\": \"aligned|watch|risk|unclear\",\n\
       \"alignment_summary\": string,\n\
       \"watch_status\": \"ok|watch|risk|unclear\",\n\
       \"watch_summary\": string,\n\
       \"evidence\": {\n\
         \"communication\": string[],\n\
         \"alignment\": string[],\n\
         \"watch\": string[]\n\
       }\n\
     }\n\n\
     Factual snapshot JSON follows:\n%s"
    (Yojson.Safe.to_string facts_json)

let parse_string_list json key =
  match member_assoc key json with
  | `List items ->
      items
      |> List.filter_map (function
           | `String value ->
               let trimmed = String.trim value in
               if trimmed = "" then None else Some trimmed
           | _ -> None)
      |> take 2
  | _ -> []

let parse_iso_opt value =
  match value with
  | Some text when String.trim text <> "" -> Some (Types.parse_iso8601 text)
  | _ -> None

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
    ]

module For_test = struct
  let compact_session_json = compact_session_json
  let compact_keeper_json = compact_keeper_json
  let compact_agent_json = compact_agent_json
  let relevant_sessions_for_briefing = relevant_sessions_for_briefing
  let collect_metadata_gaps = collect_metadata_gaps
end

let unavailable_json ~now ~reason =
  `Assoc
    [
      ("generated_at", `String now);
      ("cached", `Bool false);
      ("stale", `Bool false);
      ("refreshing", `Bool false);
      ("status", `String "unavailable");
      ("summary", `String reason);
      ("model", `Null);
      ("ttl_sec", `Int (int_of_float cache_ttl_sec));
      ("criteria", criteria_json ());
      ("sections", `List []);
      ("error", `String reason);
      ("last_error", `Null);
    ]

let error_json ~now ~reason =
  `Assoc
    [
      ("generated_at", `String now);
      ("cached", `Bool false);
      ("stale", `Bool false);
      ("refreshing", `Bool false);
      ("status", `String "error");
      ("summary", `String "Mission briefing refresh failed. Retry to request a fresh judgment.");
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

let response_accepts_json (response : Llm_client.completion_response) =
  try
    let _ = Yojson.Safe.from_string response.content in
    true
  with _ -> false

let compute_briefing_json ~actor_name ~models ~config ~sw ~clock ~proc_mgr () =
  if models = [] then
    Ok (unavailable_json ~now:(Types.now_iso ()) ~reason:no_model_reason)
  else
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
    let room_health =
      mission_summary_json |> string_field "room_health"
    in
    let incident_count = mission_summary_json |> int_field "incident_count" in
    let recommended_action_count =
      mission_summary_json |> int_field "recommended_action_count"
    in
    let facts_json =
      `Assoc
        [
          ("mission", mission_summary_json);
          ("room", member_assoc "room" snapshot_json);
          ("sessions", `List compact_sessions);
          ("keepers", `List compact_keepers);
          ("agents", `List compact_agents);
          ("recent_messages", `List messages_json);
          ("metadata_gaps", `List metadata_gaps);
        ]
    in
    let prompt = prompt_for_facts facts_json in
    let requests =
      List.map
        (fun (model : Llm_client.model_spec) ->
          {
            Llm_client.model;
            messages =
              [
                Llm_client.system_msg
                  "You are a dashboard briefing judge. Output strict JSON only.";
                Llm_client.user_msg prompt;
              ];
            temperature = 0.0;
            max_tokens = 260;
            tools = [];
            response_format = `Json;
          })
        models
    in
    match
      Llm_client.cascade ~timeout_sec:(briefing_timeout_sec ())
        ~accept:response_accepts_json requests
    with
    | Error reason -> Error reason
    | Ok response -> (
        try
          let parsed = Yojson.Safe.from_string response.content in
          let communication_status =
            string_field ~default:"unclear" "communication_status" parsed
            |> fun raw ->
            normalize_status raw
              ~allowed:[ "healthy"; "watch"; "risk"; "unclear" ]
              ~fallback:"unclear"
          in
          let alignment_status =
            string_field ~default:"unclear" "alignment_status" parsed
            |> fun raw ->
            normalize_status raw
              ~allowed:[ "aligned"; "watch"; "risk"; "unclear" ]
              ~fallback:"unclear"
          in
          let watch_status =
            string_field ~default:"unclear" "watch_status" parsed
            |> fun raw ->
            normalize_status raw
              ~allowed:[ "ok"; "watch"; "risk"; "unclear" ]
              ~fallback:"unclear"
          in
          let communication_summary =
            string_field
              ~default:"Evidence is insufficient to judge communication."
              "communication_summary" parsed
          in
          let alignment_summary =
            string_field
              ~default:"Evidence is insufficient to judge alignment."
              "alignment_summary" parsed
          in
          let watch_summary =
            string_field ~default:"No operator watch item was produced."
              "watch_summary" parsed
          in
          let evidence_json = member_assoc "evidence" parsed in
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
                ("model", `String response.model_used);
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
                ( "sections",
                  `List
                    [
                      annotate_section ~section_id:"communication"
                        ~status:communication_status ~summary:communication_summary
                        ~evidence:(parse_string_list evidence_json "communication")
                        ~metadata_gaps ~room_health ~incident_count
                        ~recommended_action_count;
                      annotate_section ~section_id:"alignment"
                        ~status:alignment_status ~summary:alignment_summary
                        ~evidence:(parse_string_list evidence_json "alignment")
                        ~metadata_gaps ~room_health ~incident_count
                        ~recommended_action_count;
                      annotate_section ~section_id:"watch"
                        ~status:watch_status ~summary:watch_summary
                        ~evidence:(parse_string_list evidence_json "watch")
                        ~metadata_gaps ~room_health ~incident_count
                        ~recommended_action_count;
                    ] );
                ("error", `Null);
                ("last_error", `Null);
              ])
        with _ -> Error "Mission briefing model returned invalid JSON." )

let start_async_refresh ~actor_name ~models ~config ~sw ~clock ~proc_mgr () =
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
             compute_briefing_json ~actor_name ~models ~config ~sw:refresh_sw ~clock
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
  let models = mission_briefing_models () in
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
      let stale = force || not is_fresh in
      let started_refresh =
        if stale && models <> [] && not refresh_in_flight then (
          start_async_refresh ~actor_name ~models ~config ~sw ~clock ~proc_mgr ();
          true)
        else
          false
      in
      let refreshing =
        refresh_in_flight || started_refresh
      in
      let delivery_error =
        if stale && models = [] then Some no_model_reason else last_error
      in
      annotate_delivery_state cached_json ~cached:true ~stale
        ~refreshing ~last_error:delivery_error
  | None ->
      if models = [] then
        unavailable_json ~now:now_iso ~reason:no_model_reason
      else if refresh_in_flight then
        pending_json ~now:now_iso ~last_error
      else (
        match (force, last_error) with
        | false, Some reason -> error_json ~now:now_iso ~reason
        | _ ->
        if not refresh_in_flight then
          start_async_refresh ~actor_name ~models ~config ~sw ~clock ~proc_mgr ();
        pending_json ~now:now_iso ~last_error)
