(** Briefing: cache, delivery state, and the public [json] entry point.
    Domain logic is split into sub-modules:
    - {!Briefing_json_helpers} -- JSON extraction / normalization
    - {!Briefing_compactors}  -- compact_*_json, session filtering
    - {!Briefing_gaps}        -- metadata gap detection
    - {!Briefing_sections}    -- section builders (communication, alignment, watch) *)

open Briefing_json_helpers

let cache_ttl_sec = Env_config.InternalTimers.briefing_cache_ttl_sec

let briefing_sections_criteria =
  [
    "deterministic_rules_only";
    "no_model_status_inference";
    "communication_from_message_and_session_counts";
    "alignment_from_active_agents_and_focus_bindings";
    "watch_from_workspace_health_and_incident_counts";
    "metadata_gaps_reported_separately";
  ]

let criteria_json () =
  `List (List.map (fun item -> `String item) briefing_sections_criteria)

(* ── Cache state ────────────────────────────────────────────────── *)

type cache_entry = {
  mutable cached_at : float;
  mutable cached_json : Yojson.Safe.t option;
  mutable refresh_in_flight : bool;
  mutable last_error : string option;
}

let cache_mutex = Eio.Mutex.create ()
let caches : (string, cache_entry) Hashtbl.t = Hashtbl.create 4

let with_cache_lock f =
  Eio.Mutex.use_ro cache_mutex f

let cache_entry_for_locked base_path =
  match Hashtbl.find_opt caches base_path with
  | Some entry -> entry
  | None ->
      let entry =
        {
          cached_at = 0.0;
          cached_json = None;
          refresh_in_flight = false;
          last_error = None;
        }
      in
      Hashtbl.replace caches base_path entry;
      entry

(* [Dashboard_briefing.json] keeps workspace_health and project in its
   [summary] object; the incidents, the recommended actions and the item that
   leads them sit beside it. The sections count those lists, so a summary key
   that no producer writes cannot read as zero (#32971). *)
let briefing_summary_of_briefing briefing_json =
  let count key =
    match member_assoc key briefing_json with
    | `List items -> Ok (List.length items)
    | other ->
      Error
        (Printf.sprintf "briefing %s is not a list: %s" key
           (Yojson.Safe.to_string other))
  in
  match count "incidents", count "recommended_actions" with
  | Error detail, _ | Ok _, Error detail -> Error detail
  | Ok incident_count, Ok recommended_action_count ->
    Ok
      (`Assoc
        [
          ( "workspace_health",
            member_assoc "summary" briefing_json |> member_assoc "workspace_health" );
          ("incident_count", `Int incident_count);
          ("recommended_action_count", `Int recommended_action_count);
          ( "top_attention_summary",
            match
              briefing_json
              |> member_assoc "command_focus"
              |> member_assoc "top_attention"
              |> member_assoc "summary"
            with
            | `String value -> `String (compact_text value)
            | other -> other );
        ])

(* ── For_test ───────────────────────────────────────────────────── *)

module For_test = struct
  let briefing_summary_of_briefing = briefing_summary_of_briefing
  let compact_agent_json = Briefing_compactors.compact_agent_json
  let collect_metadata_gaps = Briefing_gaps.collect_metadata_gaps
  let build_briefing_sections = Briefing_sections.build_briefing_sections
  let reset_cache () =
    with_cache_lock (fun () -> Hashtbl.clear caches)
  let seed_cache ~base_path ?(cached_at = 0.0) ?last_error ?(refresh_in_flight = false) json =
    with_cache_lock (fun () ->
        let entry = cache_entry_for_locked base_path in
        entry.cached_at <- cached_at;
        entry.cached_json <- Some json;
        entry.refresh_in_flight <- refresh_in_flight;
        entry.last_error <- last_error)
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
      ("summary", `String "Generating briefing from the latest snapshot.");
      ("provenance", `String "narrative");
      ("authoritative", `Bool false);
      ("model", `Null);
      ("ttl_sec", `Int (int_of_float cache_ttl_sec));
      ("criteria", criteria_json ());
      ("sections", `List []);
      ("error", `Null);
      ("last_error", Json_util.string_opt_to_json last_error);
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
  |> upsert_field "last_error" (Json_util.string_opt_to_json last_error)

(* ── Compute ────────────────────────────────────────────────────── *)

let compute_briefing_json ~actor_name ~config ~sw ~(clock : [> float Eio.Time.clock_ty ] Eio.Resource.t) ~proc_mgr () =
    let briefing_json =
      Dashboard_briefing.json ~actor:actor_name ~config ~sw ~clock ~proc_mgr ()
    in
    let keepers =
      match briefing_json |> member_assoc "keeper_briefs" with
      | `List items -> items
      | _ -> []
    in
    let agents_json = Workspace.get_agents_raw config |> List.map Briefing_compactors.compact_agent_json in
    let compact_agents = take 5 agents_json in
    let messages_json =
      Workspace.get_messages_raw config ~since_seq:0 ~limit:4
      |> List.map (fun (message : Masc_domain.message) ->
             `Assoc
               [
                 ("from", `String message.from_agent);
                 ("content", `String (compact_text ~max_len:72 message.content));
                 ("timestamp", `String message.timestamp);
               ])
    in
    match briefing_summary_of_briefing briefing_json with
    | Error detail -> Error detail
    | Ok briefing_summary_json ->
    let metadata_gaps =
      Briefing_gaps.collect_metadata_gaps ~agents:compact_agents
    in
    let watch_summary, sections =
      Briefing_sections.build_briefing_sections ~briefing_summary_json
        ~agents:compact_agents ~recent_messages:messages_json ~metadata_gaps
    in
    let now_iso = Masc_domain.now_iso () in
    (* [keeper_count] counts briefs. A Keeper the snapshot could not build a
       row for has none, so its count travels beside it (#38090). *)
    match
      Keeper_snapshot_unread.list_of_json
        (briefing_json |> member_assoc "keepers_unread")
    with
    | Error detail -> Error ("briefing keepers_unread: " ^ detail)
    | Ok keepers_unread ->
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
          ("model", `String "deterministic");
          ("ttl_sec", `Int (int_of_float cache_ttl_sec));
          ("criteria", criteria_json ());
          ("metadata_gap_count", `Int (List.length metadata_gaps));
          ("metadata_gaps", `List metadata_gaps);
          ( "basis",
            `Assoc
              [
                ( "project",
                  member_assoc "summary" briefing_json
                  |> member_assoc "project" );
                ("agent_count", `Int (List.length agents_json));
                ("keeper_count", `Int (List.length keepers));
                ("keeper_unread_count", `Int (List.length keepers_unread));
              ] );
          ("sections", `List sections);
          ("error", `Null);
          ("last_error", `Null);
        ])

(* ── Async refresh ──────────────────────────────────────────────── *)

let start_async_refresh ~actor_name ~config ~sw ~(clock : [> float Eio.Time.clock_ty ] Eio.Resource.t) ~proc_mgr () =
  let base_path = config.Workspace.base_path in
  let clear_in_flight () =
    with_cache_lock (fun () ->
        match Hashtbl.find_opt caches base_path with
        | Some entry -> entry.refresh_in_flight <- false
        | None -> ())
  in
  let should_start =
    with_cache_lock (fun () ->
        let entry = cache_entry_for_locked base_path in
        if entry.refresh_in_flight then
          false
        else (
          entry.refresh_in_flight <- true;
          true))
  in
  let refresh_sw =
    match Eio_context.get_switch_opt () with
    | Some server_sw -> server_sw
    | None -> sw
  in
  if should_start then (
    let entered = ref false in
    try
      Eio.Switch.check refresh_sw;
      (* No request waits on this refresh. *)
      Eio.Fiber.fork_daemon ~sw:refresh_sw (fun () ->
          entered := true;
          let settled = ref false in
          Fun.protect
            ~finally:(fun () ->
              if not !settled then Eio.Cancel.protect clear_in_flight)
            (fun () ->
              Pool_lane.with_background @@ fun () ->
              (try
                 let clock =
                   match Eio_context.get_clock_opt () with
                   | Some c -> c
                   | None -> (clock :> float Eio.Time.clock_ty Eio.Resource.t)
                 in
                 match
                   compute_briefing_json ~actor_name ~config ~sw:refresh_sw ~clock
                     ~proc_mgr ()
                 with
                 | Ok result_json ->
                     with_cache_lock (fun () ->
                         let entry = cache_entry_for_locked base_path in
                         entry.cached_json <- Some result_json;
                         entry.cached_at <- Unix.gettimeofday ();
                         entry.refresh_in_flight <- false;
                         entry.last_error <- None);
                     settled := true
                 | Error reason ->
                     with_cache_lock (fun () ->
                         let entry = cache_entry_for_locked base_path in
                         entry.refresh_in_flight <- false;
                         entry.last_error <- Some reason);
                     settled := true
               with
               | Eio.Cancel.Cancelled _ as e -> raise e
               | exn ->
                 with_cache_lock (fun () ->
                     let entry = cache_entry_for_locked base_path in
                     entry.refresh_in_flight <- false;
                     entry.last_error <- Some (Printexc.to_string exn));
                 settled := true));
          `Stop_daemon);
      if not !entered then clear_in_flight ()
    with
    | Eio.Cancel.Cancelled _ as e ->
      let bt = Printexc.get_raw_backtrace () in
      if not !entered then Eio.Cancel.protect clear_in_flight;
      Printexc.raise_with_backtrace e bt
    | exn ->
      let bt = Printexc.get_raw_backtrace () in
      if not !entered then clear_in_flight ();
      Printexc.raise_with_backtrace exn bt)

(* ── Public entry point ─────────────────────────────────────────── *)

let actor_name = function
  | Some value ->
      let trimmed = String.trim value in
      if trimmed <> "" then trimmed else "dashboard"
  | None -> "dashboard"

let json ?actor ?(force = false) ~config ~sw ~(clock : [> float Eio.Time.clock_ty ] Eio.Resource.t) ~proc_mgr () =
  let base_path = config.Workspace.base_path in
  let now_ts = Unix.gettimeofday () in
  let now_iso = Masc_domain.now_iso () in
  let actor_name = actor_name actor in
  let cached_json, is_fresh, refresh_in_flight, last_error =
    with_cache_lock (fun () ->
        let entry = cache_entry_for_locked base_path in
        let cached_json = entry.cached_json in
        let is_fresh =
          match cached_json with
          | Some _ -> now_ts -. entry.cached_at < cache_ttl_sec
          | None -> false
        in
        (cached_json, is_fresh, entry.refresh_in_flight, entry.last_error))
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
                let entry = cache_entry_for_locked base_path in
                entry.cached_json <- Some result_json;
                entry.cached_at <- Unix.gettimeofday ();
                entry.last_error <- None);
            result_json
        | Error reason ->
            with_cache_lock (fun () ->
                let entry = cache_entry_for_locked base_path in
                entry.last_error <- Some reason);
            (* Sync attempt failed; fall back to async + pending *)
            if not refresh_in_flight then
              start_async_refresh ~actor_name ~config ~sw ~clock ~proc_mgr ();
            pending_json ~now:now_iso ~last_error:(Some reason))
