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

type cache_state = {
  mutex : Eio.Mutex.t;
  mutable users : int;
  mutable last_used : float;
  mutable cached_at : float;
  mutable cached_json : Yojson.Safe.t option;
  mutable refresh_in_flight : bool;
  mutable last_error : string option;
}

let create_cache () =
  {
    mutex = Eio.Mutex.create ();
    users = 0;
    last_used = 0.0;
    cached_at = 0.0;
    cached_json = None;
    refresh_in_flight = false;
    last_error = None;
  }

let with_cache_lock cache f =
  Eio.Mutex.use_rw ~protect:true cache.mutex f

let actor_name = function
  | Some value when String.trim value <> "" -> String.trim value
  | Some _ | None -> "dashboard"

let caches : ((string * string), cache_state) Hashtbl.t = Hashtbl.create 8
let caches_mutex = Eio.Mutex.create ()

(* A lease prevents eviction between lookup and claiming refresh ownership.
   The table lock is always acquired before an entry lock. *)
let with_cache ~config ~actor_name f =
  let cache = Eio.Mutex.use_rw ~protect:true caches_mutex (fun () ->
    let key = Workspace_utils.masc_root_dir config, actor_name in
    let found = Hashtbl.find_opt caches key in
    let found = match found with
      | Some _ -> found
      | None ->
        if Hashtbl.length caches >= Env_config.Cache.max_entries then (
          let oldest = Hashtbl.fold (fun key cache oldest ->
            let idle = cache.users = 0 &&
              with_cache_lock cache (fun () -> not cache.refresh_in_flight) in
            if not idle then oldest else
            match oldest with
            | Some (_, used) when used <= cache.last_used -> oldest
            | _ -> Some (key, cache.last_used)) caches None in
          Option.iter (fun (key, _) -> Hashtbl.remove caches key) oldest);
        if Hashtbl.length caches >= Env_config.Cache.max_entries then None
        else let cache = create_cache () in
          Hashtbl.add caches key cache; Some cache
    in
    Option.iter (fun cache -> cache.users <- cache.users + 1;
      cache.last_used <- Unix.gettimeofday ()) found;
    found) in
  Fun.protect ~finally:(fun () -> Eio.Cancel.protect (fun () ->
    Eio.Mutex.use_rw ~protect:true caches_mutex (fun () ->
      Option.iter (fun cache -> cache.users <- cache.users - 1) cache)))
    (fun () -> f cache)

(* ── For_test ───────────────────────────────────────────────────── *)

module For_test = struct
  let cache_count () = Eio.Mutex.use_rw ~protect:true caches_mutex
      (fun () -> Hashtbl.length caches)
  let with_refresh_in_flight ~config f =
    with_cache ~config ~actor_name:"dashboard" (function
      | None -> invalid_arg "briefing cache capacity exhausted"
      | Some cache ->
        with_cache_lock cache (fun () -> cache.refresh_in_flight <- true);
        Fun.protect ~finally:(fun () -> Eio.Cancel.protect (fun () ->
          with_cache_lock cache (fun () -> cache.refresh_in_flight <- false))) f)
  let compact_keeper_json = Briefing_compactors.compact_keeper_json
  let compact_agent_json = Briefing_compactors.compact_agent_json
  let collect_metadata_gaps = Briefing_gaps.collect_metadata_gaps
  let build_briefing_sections = Briefing_sections.build_briefing_sections
  let reset_cache () =
    Eio.Mutex.use_rw ~protect:true caches_mutex (fun () -> Hashtbl.clear caches)
  let seed_cache ~config ?actor ?(cached_at = 0.0) ?last_error ?(refresh_in_flight = false) json =
    with_cache ~config ~actor_name:(actor_name actor) (function
    | None -> invalid_arg "briefing cache capacity exhausted"
    | Some cache -> with_cache_lock cache (fun () ->
        cache.cached_at <- cached_at;
        cache.cached_json <- Some json;
        cache.refresh_in_flight <- refresh_in_flight;
        cache.last_error <- last_error))
end

(* ── Response envelope builders ─────────────────────────────────── *)

let pending_json ?(refreshing = true) ~now ~last_error () =
  `Assoc
    [
      ("generated_at", `String now);
      ("cached", `Bool false);
      ("stale", `Bool false);
      ("refreshing", `Bool refreshing);
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
    let compact_keepers = take 3 (List.map Briefing_compactors.compact_keeper_json keepers) in
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
    let ( let* ) = Result.bind in
    let* briefing_summary_json =
      Briefing_compactors.compact_briefing_summary_json briefing_json
    in
    let metadata_gaps =
      Briefing_gaps.collect_metadata_gaps ~keepers:compact_keepers ~agents:compact_agents
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

let start_async_refresh ~cache ~actor_name ~config ~sw ~(clock : [> float Eio.Time.clock_ty ] Eio.Resource.t) ~proc_mgr () =
  let should_start =
    with_cache_lock cache (fun () ->
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
  let release ?error () = Eio.Cancel.protect (fun () ->
    with_cache_lock cache (fun () ->
      cache.refresh_in_flight <- false;
      Option.iter (fun detail -> cache.last_error <- Some detail) error)) in
  if should_start then try
    Eio.Fiber.fork_daemon ~sw:refresh_sw (fun () ->
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
               with_cache_lock cache (fun () ->
                   cache.cached_json <- Some result_json;
                   cache.cached_at <- Unix.gettimeofday ();
                   cache.refresh_in_flight <- false;
                   cache.last_error <- None)
           | Error reason ->
               with_cache_lock cache (fun () ->
                   cache.refresh_in_flight <- false;
                   cache.last_error <- Some reason)
         with
         | Eio.Cancel.Cancelled _ as e ->
           release ();
           raise e
         | exn ->
           release ~error:(Printexc.to_string exn) ());
        `Stop_daemon)
  with
  | Eio.Cancel.Cancelled _ as e -> release (); raise e
  | exn -> release ~error:(Printexc.to_string exn) ()

(* ── Public entry point ─────────────────────────────────────────── *)

let json ?actor ?(force = false) ~config ~sw ~(clock : [> float Eio.Time.clock_ty ] Eio.Resource.t) ~proc_mgr () =
  let now_ts = Unix.gettimeofday () in
  let now_iso = Masc_domain.now_iso () in
  let actor_name = actor_name actor in
  with_cache ~config ~actor_name (function
  | None -> pending_json ~refreshing:false ~now:now_iso
      ~last_error:(Some "Briefing cache capacity is busy; retry later.") ()
  | Some cache ->
  let cached_json, is_fresh, refresh_in_flight, last_error =
    with_cache_lock cache (fun () ->
        let cached_json = cache.cached_json in
        let is_fresh =
          match cached_json with
          | Some _ -> now_ts -. cache.cached_at < cache_ttl_sec
          | None -> false
        in
        let already_refreshing = cache.refresh_in_flight in
        if cached_json = None && not force && not already_refreshing then
          cache.refresh_in_flight <- true;
        (cached_json, is_fresh, already_refreshing, cache.last_error))
  in
  match cached_json with
  | Some cached_json ->
      if not force && is_fresh then
        annotate_delivery_state cached_json ~cached:true ~stale:false
          ~refreshing:refresh_in_flight ~last_error
      else (
        if not refresh_in_flight then
          start_async_refresh ~cache ~actor_name ~config ~sw ~clock ~proc_mgr ();
        annotate_delivery_state cached_json ~cached:true ~stale:true
          ~refreshing:true ~last_error)
  | None ->
      if force || refresh_in_flight then (
        if not refresh_in_flight then
          start_async_refresh ~cache ~actor_name ~config ~sw ~clock ~proc_mgr ();
        pending_json ~now:now_iso ~last_error ())
      else
        (* The cold caller claimed ownership with the snapshot above. Followers
           observe pending until this computation publishes or releases it. *)
        Fun.protect
          ~finally:(fun () -> Eio.Cancel.protect (fun () ->
            with_cache_lock cache (fun () -> cache.refresh_in_flight <- false)))
          (fun () ->
            match compute_briefing_json ~actor_name ~config ~sw ~clock ~proc_mgr () with
            | Ok result_json ->
                with_cache_lock cache (fun () ->
                  cache.cached_json <- Some result_json;
                  cache.cached_at <- Unix.gettimeofday ();
                  cache.last_error <- None);
                result_json
            | Error reason ->
                with_cache_lock cache (fun () -> cache.last_error <- Some reason);
                pending_json ~refreshing:false ~now:now_iso
                  ~last_error:(Some reason) ()))
