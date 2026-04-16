(** Mission briefing: cache, delivery state, and the public [json] entry point.
    Domain logic is split into sub-modules:
    - {!Briefing_json_helpers} -- JSON extraction / normalization
    - {!Briefing_compactors}  -- compact_*_json, session filtering
    - {!Briefing_gaps}        -- metadata gap detection
    - {!Briefing_sections}    -- section builders (communication, alignment, watch) *)

open Briefing_json_helpers

let cache_ttl_sec = Env_config.InternalTimers.briefing_cache_ttl_sec

let mission_briefing_surface_contract_json =
  `Assoc
    [
      ("summary", `String "narrative");
      ("sections", `String "narrative");
      ("basis", `String "truth");
    ]

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

(* ── Cache state ────────────────────────────────────────────────── *)

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

(* ── For_test ───────────────────────────────────────────────────── *)

module For_test = struct
  let compact_session_json = Briefing_compactors.compact_session_json
  let compact_keeper_json = Briefing_compactors.compact_keeper_json
  let compact_agent_json = Briefing_compactors.compact_agent_json
  let relevant_sessions_for_briefing = Briefing_compactors.relevant_sessions_for_briefing
  let collect_metadata_gaps = Briefing_gaps.collect_metadata_gaps
  let build_briefing_sections = Briefing_sections.build_briefing_sections
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

(* ── Response envelope builders ─────────────────────────────────── *)

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

(* ── Compute ────────────────────────────────────────────────────── *)

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
        net = None;
        mcp_session_id = None;
      }
    in
    let snapshot_json =
      (* Reuse the same lightweight summary shape as the operator/mission
         dashboard surfaces. The briefing only needs session status/events;
         keeper metadata can come from mission_json. Pulling keepers,
         command-plane, and message payloads here duplicates the heaviest
         snapshot path and can spike memory on rooms with many keepers. *)
      Operator_control.snapshot_json ~actor:actor_name ~view:"summary"
        ~include_messages:false ~include_keepers:false
        ~include_summary_fields:false
        ~lightweight_summary:true ctx
    in
    let scope_json =
      match snapshot_json |> member_assoc "root" with
      | `Assoc _ as value -> value
      | _ -> snapshot_json |> member_assoc "room"
    in
    let current_namespace =
      match trim_to_option (Some (scope_json |> string_field "project")) with
      | Some value -> value
      | None -> "default"
    in
    let sessions =
      Briefing_compactors.relevant_sessions_for_briefing ~current_namespace
        ~now_ts []
    in
    let keepers =
      match mission_json |> member_assoc "keeper_briefs" with
      | `List items -> items
      | _ -> []
    in
    let compact_sessions = take 3 (List.map Briefing_compactors.compact_session_json sessions) in
    let compact_keepers = take 3 (List.map Briefing_compactors.compact_keeper_json keepers) in
    let agents_json = Coord.get_agents_raw config |> List.map Briefing_compactors.compact_agent_json in
    let compact_agents = take 5 agents_json in
    let messages_json =
      Coord.get_messages_raw config ~since_seq:0 ~limit:4
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
      Briefing_gaps.collect_metadata_gaps ~sessions:compact_sessions ~keepers:compact_keepers
        ~agents:compact_agents
    in
    let watch_summary, sections =
      Briefing_sections.build_briefing_sections ~mission_summary_json ~sessions:compact_sessions
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
                ( "project",
                  member_assoc "summary" mission_json
                  |> member_assoc "project" );
                ("crew_count", `Int (List.length sessions));
                ("agent_count", `Int (List.length agents_json));
                ("keeper_count", `Int (List.length keepers));
              ] );
          ("sections", `List sections);
          ("error", `Null);
          ("last_error", `Null);
        ])

(* ── Async refresh ──────────────────────────────────────────────── *)

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
         with
         | Eio.Cancel.Cancelled _ as e -> raise e
         | exn ->
           with_cache_lock (fun () ->
               cache.refresh_in_flight <- false;
               cache.last_error <- Some (Printexc.to_string exn)));
        `Stop_daemon)

(* ── Public entry point ─────────────────────────────────────────── *)

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
      else (
        (* Synchronous cold-start: compute the first briefing inline so the
           caller gets an immediate "ok" result instead of "pending".
           Subsequent calls hit the cache or the async refresh path. *)
        match compute_briefing_json ~actor_name ~config ~sw ~clock ~proc_mgr () with
        | Ok result_json ->
            with_cache_lock (fun () ->
                cache.cached_json <- Some result_json;
                cache.cached_at <- Unix.gettimeofday ();
                cache.last_error <- None);
            result_json
        | Error _reason ->
            (* Sync attempt failed; fall back to async + pending *)
            if not refresh_in_flight then
              start_async_refresh ~actor_name ~config ~sw ~clock ~proc_mgr ();
            pending_json ~now:now_iso ~last_error)
