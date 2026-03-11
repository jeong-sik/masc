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

let rec take n = function
  | [] -> []
  | _ when n <= 0 -> []
  | x :: xs -> x :: take (n - 1) xs

let option_string_json = function
  | Some value when String.trim value <> "" -> `String (String.trim value)
  | _ -> `Null

let normalize_status raw ~allowed ~fallback =
  let lowered = String.trim raw |> String.lowercase_ascii in
  if List.mem lowered allowed then lowered else fallback

(** Model specs for mission briefing LLM cascade.
    Delegates to Lodge_cascade for hot-reloadable config and built-in defaults.
    Override via config/llm_cascade.json key "briefing_models". *)
let mission_briefing_models () =
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

let compact_session_json session_json =
  let session = member_assoc "session" session_json in
  let summary = member_assoc "summary" session_json in
  let team_health = member_assoc "team_health" session_json in
  let communication = member_assoc "communication_metrics" session_json in
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
            ("event_type", member_assoc "event_type" latest);
            ("ts_iso", member_assoc "ts_iso" latest);
            ("actor", member_assoc "actor" detail);
            ("task_title", member_assoc "task_title" detail);
            ("result", member_assoc "result" detail);
            ("reason", member_assoc "reason" detail);
          ]
    | [] -> `Null
  in
  `Assoc
    [
      ("session_id", member_assoc "session_id" session_json);
      ( "goal",
        match member_assoc "goal" session with
        | `String value -> `String (compact_text value)
        | other -> other );
      ("room_id", member_assoc "room_id" session);
      ("status", member_assoc "status" session);
      ("agent_names", member_assoc "agent_names" session);
      ("elapsed_sec", member_assoc "elapsed_sec" summary);
      ("progress_pct", member_assoc "progress_pct" summary);
      ("done_delta_total", member_assoc "done_delta_total" summary);
      ("team_health", member_assoc "status" team_health);
      ("active_agents_count", member_assoc "active_agents_count" team_health);
      ("required_agents", member_assoc "required_agents" team_health);
      ("communication_mode", member_assoc "mode" communication);
      ("broadcast_count", member_assoc "broadcast_count" communication);
      ("portal_count", member_assoc "portal_count" communication);
      ("last_event", last_event);
    ]

let compact_keeper_json keeper_json =
  let diagnostic = member_assoc "diagnostic" keeper_json in
  let agent = member_assoc "agent" keeper_json in
  `Assoc
    [
      ("name", member_assoc "name" keeper_json);
      ("status", member_assoc "status" keeper_json);
      ("agent_name", member_assoc "agent_name" keeper_json);
      ("generation", member_assoc "generation" keeper_json);
      ("context_ratio", member_assoc "context_ratio" keeper_json);
      ("last_turn_ago_s", member_assoc "last_turn_ago_s" keeper_json);
      ("compaction_count", member_assoc "compaction_count" keeper_json);
      ("handoff_count_total", member_assoc "handoff_count_total" keeper_json);
      ( "current_task",
        match member_assoc "current_task" agent with
        | `String value -> `String (compact_text value)
        | other -> other );
      ("last_reply_status", member_assoc "last_reply_status" diagnostic);
      ( "last_reply_preview",
        match member_assoc "last_reply_preview" diagnostic with
        | `String value -> `String (compact_text value)
        | other -> other );
      ("active_goal_ids", member_assoc "active_goal_ids" keeper_json);
      ( "skill_primary",
        match member_assoc "skill_primary" keeper_json with
        | `String value -> `String (compact_text value)
        | other -> other );
    ]

let section_json ~id ~label ~status ~summary ~evidence =
  `Assoc
    [
      ("id", `String id);
      ("label", `String label);
      ("status", `String status);
      ("summary", `String summary);
      ("evidence", `List (List.map (fun item -> `String item) evidence));
    ]

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
    let keepers =
      match snapshot_json |> member_assoc "keepers" |> member_assoc "items" with
      | `List items -> items
      | _ -> []
    in
    let agents_json =
      Room.get_agents_raw config
      |> List.map (fun (agent : Types.agent) ->
             `Assoc
               [
                 ("name", `String agent.name);
                 ("agent_type", `String agent.agent_type);
                 ("status", `String (Types.string_of_agent_status agent.status));
                 ("current_task", option_string_json (Option.map compact_text agent.current_task));
                 ("joined_at", `String agent.joined_at);
                 ("last_seen", `String agent.last_seen);
                 ("capabilities", `List (List.map (fun item -> `String item) (take 2 agent.capabilities)));
               ])
    in
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
    let facts_json =
      `Assoc
        [
          ("mission", mission_summary_json);
          ("room", member_assoc "room" snapshot_json);
          ("sessions", `List (take 3 (List.map compact_session_json sessions)));
          ("keepers", `List (take 3 (List.map compact_keeper_json keepers)));
          ("agents", `List (take 5 agents_json));
          ("recent_messages", `List messages_json);
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
                      section_json ~id:"communication" ~label:"Communication"
                        ~status:communication_status ~summary:communication_summary
                        ~evidence:(parse_string_list evidence_json "communication");
                      section_json ~id:"alignment" ~label:"Alignment"
                        ~status:alignment_status ~summary:alignment_summary
                        ~evidence:(parse_string_list evidence_json "alignment");
                      section_json ~id:"watch" ~label:"Watch Next"
                        ~status:watch_status ~summary:watch_summary
                        ~evidence:(parse_string_list evidence_json "watch");
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
