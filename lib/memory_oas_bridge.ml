(** Memory_oas_bridge — MASC-side adapter that projects product memory into
    OAS Memory.t 5-tier primitives.

    Tier mapping:
    - {b Long_term} — JSONL files under [.masc/memory/<agent>/<session>.jsonl]
    - {b Episodic}  — [load_episodes_text] reads recent [Institution_eio] JSONL
                       episodes; [flush_episodes] writes new OAS episodes back
    - {b Procedural} — [load_procedures_text] reads [Procedural_memory] entries;
                        [flush_procedures] writes back
    - {b Working/Scratchpad} — managed by OAS in-memory; no backend needed

    Memory injection follows the hook-first pattern (RFC-MASC-004):
    pure-read [load_*_text] functions provide text for system context
    injection via hooks, and [flush_incremental] persists new data
    after each turn.  The imperative seeding functions
    ([seed_episodes], [seed_procedures_as_oas], [create_memory_full])
    were removed in Phase 3.

    Filesystem-first policy: Long_term always uses JSONL, regardless of
    whether a PG pool is available.  PG long_term was removed in 2.140.0.

    @since 2.122.0 (long_term only)
    @since 2.124.0 (5-tier: episodic + procedural seeding/flushing)
    @since 2.140.0 (filesystem-first: JSONL long_term_backend always)
    @since 2.266.0 (RFC-MASC-004 Phase 3: imperative seeding removed) *)

(** Default importance for memories stored via OAS Memory.store.
    Configurable via MASC_MEMORY_OAS_DEFAULT_IMPORTANCE. *)
let default_importance () = Env_config.Memory_oas.default_importance

(** Extract importance from JSON value if present, else use default. *)
let importance_of_json (json : Yojson.Safe.t) : int =
  match json with
  | `Assoc fields ->
    (match List.assoc_opt "importance" fields with
     | Some (`Int n) -> max 1 (min 10 n)
     | _ -> default_importance ())
  | _ -> default_importance ()

(** Extract content string from JSON value. *)
let content_of_json (json : Yojson.Safe.t) : string =
  match json with
  | `String s -> s
  | `Assoc fields ->
    (match List.assoc_opt "content" fields with
     | Some (`String s) -> s
     | _ -> Yojson.Safe.to_string json)
  | _ -> Yojson.Safe.to_string json

(** Generate a timestamp-based session ID as fallback. *)
let generate_session_id () =
  Printf.sprintf "%d" (int_of_float (Unix.gettimeofday ()))

(** Resolve the JSONL fallback root for OAS memory.

    Preference order:
    1. Explicit [base_dir]
    2. Room-scoped [.masc] under [config.base_path]
    3. Process-scoped [.masc] under [MASC_BASE_PATH] (or cwd fallback) *)
let resolve_base_dir ?(base_dir : string option) ?(config : Room_utils.config option) () =
  match base_dir, config with
  | Some dir, _ -> dir
  | None, Some cfg -> Filename.concat cfg.base_path ".masc"
  | None, None -> Filename.concat (Env_config.base_path ()) ".masc"

type file_stamp = float * int

let file_stamp_opt path =
  try
    let stats = Unix.stat path in
    Some (stats.Unix.st_mtime, stats.Unix.st_size)
  with
  | Unix.Unix_error _ -> None
  | Sys_error _ -> None

type episode_file_cache = {
  mutable stamp : file_stamp option;
  mutable episodes : Institution_eio.episode list;
  mutable ids : (string, unit) Hashtbl.t;
}

let episode_file_cache_tbl : (string, episode_file_cache) Hashtbl.t =
  Hashtbl.create 4

let episode_cache_mu = Eio.Mutex.create ()

let episode_ids_of episodes =
  let ids = Hashtbl.create (max 16 (List.length episodes)) in
  List.iter
    (fun (episode : Institution_eio.episode) -> Hashtbl.replace ids episode.id ())
    episodes;
  ids

(* Keep at most this many episodes in the in-memory cache.
   Callers that need fewer use cached_recent_episodes ~limit. *)
let episode_cache_limit = 500

(* Pure cache construction: stat + JSONL read + build a fresh
   [episode_file_cache].  Touches no shared state, so safe to run
   with no lock held. *)
let build_episode_cache_from_disk path =
  let stamp = file_stamp_opt path in
  let episodes =
    Institution_eio.load_recent_episodes_jsonl ~limit:episode_cache_limit
  in
  { stamp; episodes; ids = episode_ids_of episodes }

(* Cache-aware episode loader.

   Previously held [episode_cache_mu] across
   [Institution_eio.load_recent_episodes_jsonl] on every cache miss,
   meaning all concurrent [persisted_episode_ids]
   / [cached_recent_episodes] callers serialised on a single JSONL
   read of up to [episode_cache_limit = 500] records.  Same drift
   class as the [Prompt_registry] / [Discovery_cache] siblings fixed
   in PRs #6663 / #6668 — an [_unlocked] helper was called from
   inside the caller's [with_mutex], re-introducing the
   I/O-under-lock anti-pattern.

   Split into:
   1. Stamp check under the mutex (pure [Hashtbl.find_opt] +
      [Unix.stat]).
   2. Hot path returns the cached record if the stamp still matches.
   3. On miss, release the lock, build the cache from disk outside
      the lock, install under a fresh short mutex section.

   Concurrent misses may both run the JSONL read; that is wasteful
   but correct (the last writer wins on [Hashtbl.replace]).  In
   practice the stamp check short-circuits the vast majority of
   calls. *)
let load_all_episodes_cached () =
  let path = Institution_eio.episodes_jsonl_path () in
  let cached_opt =
    Eio_guard.with_mutex episode_cache_mu (fun () ->
      let current_stamp = file_stamp_opt path in
      match Hashtbl.find_opt episode_file_cache_tbl path with
      | Some cache when cache.stamp = current_stamp -> Some cache
      | _ -> None)
  in
  match cached_opt with
  | Some cache -> cache
  | None ->
      (* JSONL read OUTSIDE the mutex. *)
      let fresh = build_episode_cache_from_disk path in
      Eio_guard.with_mutex episode_cache_mu (fun () ->
        Hashtbl.replace episode_file_cache_tbl path fresh);
      fresh

let rec drop_list n = function
  | [] -> []
  | remaining when n <= 0 -> remaining
  | _ :: rest -> drop_list (n - 1) rest

let cached_recent_episodes ~limit =
  let cache = load_all_episodes_cached () in
  let total = List.length cache.episodes in
  if total <= limit then cache.episodes
  else drop_list (total - limit) cache.episodes

(* Record an episode that was just appended to the JSONL file.

   Previously called [load_all_episodes_cached_unlocked] while
   holding [episode_cache_mu], which meant a cache-miss during
   flush would block on the same under-mutex JSONL read the main
   fix addresses above.  Instead, look the cache up in place: if
   it exists, mutate in place (fast path — no I/O); if it's
   missing, skip — the next [load_all_episodes_cached] call will
   populate a fresh cache from disk including the newly-appended
   episode.

   The [stamp] update keeps the cache in sync with the file's new
   mtime so subsequent loaders do not trigger a reload purely
   because [note_episode_flush] just wrote to the file. *)
let note_episode_flush (episode : Institution_eio.episode) =
  let path = Institution_eio.episodes_jsonl_path () in
  Eio_guard.with_mutex episode_cache_mu (fun () ->
    match Hashtbl.find_opt episode_file_cache_tbl path with
    | None -> ()  (* No cache to update; next loader will populate fresh *)
    | Some cache ->
      if not (Hashtbl.mem cache.ids episode.id) then begin
        let episodes = cache.episodes @ [episode] in
        (* Trim oldest entries when cache exceeds limit *)
        let total = List.length episodes in
        let episodes =
          if total > episode_cache_limit then
            let drop_n = total - episode_cache_limit in
            let rec drop_with_evict n = function
              | [] -> []
              | remaining when n <= 0 -> remaining
              | (ep : Institution_eio.episode) :: rest ->
                  Hashtbl.remove cache.ids ep.id;
                  drop_with_evict (n - 1) rest
            in
            drop_with_evict drop_n episodes
          else
            episodes
        in
        cache.episodes <- episodes;
        Hashtbl.replace cache.ids episode.id ();
      end;
      cache.stamp <- file_stamp_opt path;
      Hashtbl.replace episode_file_cache_tbl path cache)

type procedure_file_cache = {
  mutable stamp : file_stamp option;
  mutable procedures : Procedural_memory.procedure list;
}

let procedure_file_cache_tbl : (string, procedure_file_cache) Hashtbl.t =
  Hashtbl.create 16

let procedure_cache_mu = Eio.Mutex.create ()

let load_procedures_cached ~(agent_name : string) =
  Eio_guard.with_mutex procedure_cache_mu (fun () ->
    let path = Procedural_memory.procedures_path ~agent_name in
    let stamp = file_stamp_opt path in
    match Hashtbl.find_opt procedure_file_cache_tbl path with
    | Some cache when cache.stamp = stamp -> cache.procedures
    | _ ->
        let procedures = Procedural_memory.load_procedures ~agent_name in
        Hashtbl.replace procedure_file_cache_tbl path { stamp; procedures };
        procedures)

let store_procedures_cache ~(agent_name : string)
    (procedures : Procedural_memory.procedure list) =
  Eio_guard.with_mutex procedure_cache_mu (fun () ->
    let path = Procedural_memory.procedures_path ~agent_name in
    let stamp = file_stamp_opt path in
    Hashtbl.replace procedure_file_cache_tbl path { stamp; procedures })

let top_procedures_cached ~(agent_name : string) ~(limit : int) =
  load_procedures_cached ~agent_name
  |> List.filter Procedural_memory.is_crystallized
  |> List.sort (fun (a : Procedural_memory.procedure) (b : Procedural_memory.procedure) ->
         Float.compare b.confidence a.confidence)
  |> List.filteri (fun i _ -> i < limit)

(** Create an OAS [long_term_backend].

    Always uses session-based JSONL files under
    [.masc/memory/<agent_name>/<session_id>.jsonl].
    Filesystem-first: PG pool availability is not checked. *)
let make_backend ?base_dir ~(agent_name : string) ~(session_id : string) ()
  : Agent_sdk.Memory.long_term_backend =
  let base_dir = resolve_base_dir ?base_dir () in
  Memory_jsonl.make_backend ~base_dir ~agent_name ~session_id

(** Create an OAS [Memory.t] instance.

    Uses JSONL long_term_backend (filesystem-first).
    @param session_id Session identifier; defaults to timestamp-based ID. *)
let create_memory ~(agent_name : string) ?(base_dir : string option)
    ?(session_id : string option)
    () : Agent_sdk.Memory.t =
  let sid = match session_id with
    | Some s -> s
    | None -> generate_session_id ()
  in
  let backend = make_backend ?base_dir ~agent_name ~session_id:sid () in
  Agent_sdk.Memory.create ~long_term:backend ()

(** Load and return the institution welcome text, or [None] when empty.
    Used by [load_institution_text]. *)
let read_institution_welcome (config : Room_utils.config) : string option =
  let welcome = Institution_eio.load_and_format_for_welcome ~fs:() config in
  if welcome = "" then None else Some welcome

(* ================================================================ *)
(* Episodic tier: Institution_eio JSONL <-> OAS episodes            *)
(* ================================================================ *)

let default_episode_salience (episode : Institution_eio.episode) =
  let base =
    match episode.outcome with
    | `Success -> 0.75
    | `Failure -> 0.95
    | `Partial -> 0.6
  in
  let learning_bonus =
    min 0.15 (float_of_int (List.length episode.learnings) *. 0.03)
  in
  Float.min 1.0 (base +. learning_bonus)

let oas_outcome_of_institution (episode : Institution_eio.episode) =
  match episode.outcome with
  | `Success -> Agent_sdk.Memory.Success episode.summary
  | `Failure -> Agent_sdk.Memory.Failure episode.summary
  | `Partial -> Agent_sdk.Memory.Neutral

let metadata_string key metadata =
  match List.assoc_opt key metadata with
  | Some (`String value) when String.trim value <> "" -> Some value
  | _ -> None

let metadata_string_list key metadata =
  match List.assoc_opt key metadata with
  | Some (`List values) ->
      values
      |> List.filter_map (function
           | `String value when String.trim value <> "" -> Some value
           | _ -> None)
  | _ -> []

let metadata_context key metadata =
  match List.assoc_opt key metadata with
  | Some (`Assoc fields) ->
      fields
      |> List.filter_map (function
           | k, `String value -> Some (k, value)
           | _ -> None)
  | _ -> []

let metadata_float key metadata =
  match List.assoc_opt key metadata with
  | Some (`Float value) -> Some value
  | Some (`Int value) -> Some (float_of_int value)
  | Some (`Intlit value) -> Some (float_of_string value)
  | _ -> None

let institution_outcome_to_string = function
  | `Success -> "success"
  | `Failure -> "failure"
  | `Partial -> "partial"

let institution_outcome_of_string = function
  | "success" -> Some `Success
  | "failure" -> Some `Failure
  | "partial" -> Some `Partial
  | _ -> None

let oas_episode_of_institution (episode : Institution_eio.episode) :
    Agent_sdk.Memory.episode =
  {
    id = episode.id;
    timestamp = episode.timestamp;
    participants = episode.participants;
    action = episode.summary;
    outcome = oas_outcome_of_institution episode;
    salience = default_episode_salience episode;
    metadata =
      [
        ("event_type", `String episode.event_type);
        ("institution_summary", `String episode.summary);
        ( "institution_outcome",
          `String (institution_outcome_to_string episode.outcome) );
        ( "learnings",
          `List (List.map (fun learning -> `String learning) episode.learnings)
        );
        ( "context",
          `Assoc
            (List.map (fun (key, value) -> (key, `String value)) episode.context)
        );
        ("source", `String "institution_jsonl");
      ];
  }

let institution_episode_of_oas ~(agent_name : string)
    (episode : Agent_sdk.Memory.episode) : Institution_eio.episode =
  let summary =
    metadata_string "institution_summary" episode.metadata
    |> Option.value ~default:episode.action
  in
  let event_type =
    metadata_string "event_type" episode.metadata
    |> Option.value ~default:"oas_memory"
  in
  let learnings = metadata_string_list "learnings" episode.metadata in
  let context = metadata_context "context" episode.metadata in
  let outcome =
    match
      Option.bind
        (metadata_string "institution_outcome" episode.metadata)
        institution_outcome_of_string
    with
    | Some preserved -> preserved
    | None -> (
        match episode.outcome with
        | Agent_sdk.Memory.Success _ -> `Success
        | Agent_sdk.Memory.Failure _ -> `Failure
        | Agent_sdk.Memory.Neutral -> `Partial)
  in
  let participants =
    if episode.participants <> [] then episode.participants
    else [ agent_name ]
  in
  {
    Institution_eio.id = episode.id;
    timestamp =
      metadata_float "timestamp" episode.metadata
      |> Option.value ~default:episode.timestamp;
    participants;
    event_type;
    summary;
    outcome;
    learnings;
    context;
  }

(** Create an OAS episode from a keeper [STATE] snapshot and store it
    in [Memory.t].  The episode is later flushed to institution JSONL by
    the AfterTurn hook's [flush_episodes].

    Metadata keys match what [institution_episode_of_oas] expects, so
    the round-trip Institution_eio -> OAS -> Institution_eio is lossless. *)
let store_episode_from_snapshot
    ~(memory : Agent_sdk.Memory.t)
    ~(keeper_name : string)
    ~(turn : int)
    ~(trace_id : string)
    (snapshot : Keeper_memory_policy.keeper_state_snapshot) : unit =
  let parts =
    List.filter_map Fun.id
      [
        Option.map (fun g -> "Goal: " ^ g) snapshot.goal;
        Option.map (fun p -> "Progress: " ^ p) snapshot.progress;
        Option.map (fun d -> "Done: " ^ d) snapshot.done_summary;
      ]
  in
  let summary =
    match parts with
    | [] -> "keeper turn " ^ string_of_int turn
    | _ -> String.concat "; " parts
  in
  let learnings =
    (snapshot.decisions @ snapshot.constraints)
    |> List.filter (fun s -> String.trim s <> "")
  in
  let outcome_str, outcome =
    if snapshot.done_summary <> None then
      ("success", Agent_sdk.Memory.Success summary)
    else ("partial", Agent_sdk.Memory.Neutral)
  in
  let ts = Time_compat.now () in
  let episode_id =
    Printf.sprintf "keeper-%s-t%d-%d" keeper_name turn
      (int_of_float (ts *. 1000.0) mod 1_000_000)
  in
  let episode : Agent_sdk.Memory.episode =
    {
      id = episode_id;
      timestamp = ts;
      participants = [ keeper_name ];
      action = summary;
      outcome;
      salience = 0.6;
      metadata =
        [
          ("event_type", `String "keeper_turn");
          ("institution_summary", `String summary);
          ("institution_outcome", `String outcome_str);
          ( "learnings",
            `List (List.map (fun l -> `String l) learnings) );
          ( "context",
            `Assoc
              [
                ("trace_id", `String trace_id);
                ("turn", `String (string_of_int turn));
              ] );
        ];
    }
  in
  Agent_sdk.Memory.store_episode memory episode

let persisted_episode_ids () =
  Hashtbl.copy (load_all_episodes_cached ()).ids

(** Flush new OAS episodes.

    Appends newly created OAS episodes to the institution JSONL store,
    preserving IDs and institution metadata when present. *)
let flush_episodes ~(memory : Agent_sdk.Memory.t) ~(agent_name : string) : int =
  let persisted_ids = persisted_episode_ids () in
  let path = Institution_eio.episodes_jsonl_path () in
  Fs_compat.mkdir_p (Filename.dirname path);
  Agent_sdk.Memory.recall_episodes memory ~limit:max_int ()
  |> List.fold_left
       (fun flushed (episode : Agent_sdk.Memory.episode) ->
         if Hashtbl.mem persisted_ids episode.id then flushed
         else (
           let persisted = institution_episode_of_oas ~agent_name episode in
           Hashtbl.replace persisted_ids episode.id ();
           Fs_compat.append_jsonl path
             (Institution_eio.episode_to_json persisted);
           note_episode_flush persisted;
           flushed + 1))
       0

(* ================================================================ *)
(* Procedural tier: Procedural_memory <-> OAS procedures            *)
(* ================================================================ *)

(** Convert a [Procedural_memory.procedure] to an OAS [procedure].

    MASC's [pattern] field contains "When X, do Y" as a single string.
    OAS separates [pattern] (trigger) from [action] (what to do).
    We use the full string for both fields since they are combined
    in MASC's representation. *)
let oas_procedure_of_masc (p : Procedural_memory.procedure) :
    Agent_sdk.Memory.procedure =
  {
    id = p.id;
    pattern = p.pattern;
    action = p.pattern;  (* MASC combines trigger+action in pattern *)
    success_count = p.success_count;
    failure_count = p.failure_count;
    confidence = p.confidence;
    last_used = p.last_applied;
    metadata = [
      ("agent_name", `String p.agent_name);
      ("created_at", `Float p.created_at);
      ("evidence_count", `Int (List.length p.evidence));
    ];
  }

let render_lesson_prompt_context ~(memory : Agent_sdk.Memory.t)
    ~(pattern : string) ~(limit : int) =
  Agent_sdk.Lesson_memory.retrieve_lessons memory ~pattern ~limit ()
  |> Agent_sdk.Lesson_memory.render_prompt_context

let record_failure_lesson ~(memory : Agent_sdk.Memory.t)
    ~(pattern : string) ~(summary : string)
    ?action ?stdout ?stderr ?diff_summary ?trace_summary ?metric_name
    ?metric_error ~(participants : string list)
    ~(metadata : (string * Yojson.Safe.t) list) () =
  ignore
    (Agent_sdk.Lesson_memory.record_failure memory
       {
         pattern;
         summary;
         action;
         stdout;
         stderr;
         diff_summary;
         trace_summary;
         metric_name;
         metric_error;
         participants;
         metadata;
       })

let dedupe_procedures_by_id (procs : Procedural_memory.procedure list) =
  let latest_by_id = Hashtbl.create (max 16 (List.length procs)) in
  List.iter (fun (p : Procedural_memory.procedure) ->
    Hashtbl.replace latest_by_id p.id p
  ) procs;
  let seen = Hashtbl.create (Hashtbl.length latest_by_id) in
  List.filter_map (fun (p : Procedural_memory.procedure) ->
    if Hashtbl.mem seen p.id then None
    else begin
      Hashtbl.add seen p.id ();
      Hashtbl.find_opt latest_by_id p.id
    end
  ) procs

(** Flush OAS procedures back to [Procedural_memory].

    Extracts procedures from the Procedural tier that have been updated
    (new success/failure counts) and persists them.
    Returns the number of procedures flushed. *)
let flush_procedures ~(memory : Agent_sdk.Memory.t) ~(agent_name : string) : int =
  let oas_procs =
    Agent_sdk.Memory.matching_procedures memory
      ~pattern:"" ()
  in
  let existing_raw = load_procedures_cached ~agent_name in
  let procedures = ref (dedupe_procedures_by_id existing_raw) in
  let needs_rewrite = ref (List.length existing_raw <> List.length !procedures) in
  let flushed = ref 0 in
  List.iter (fun (op : Agent_sdk.Memory.procedure) ->
    let updated =
      match List.find_opt (fun (p : Procedural_memory.procedure) ->
        p.id = op.id
      ) !procedures with
      | Some old_p ->
        (* Only flush if counts changed *)
        if old_p.success_count <> op.success_count
           || old_p.failure_count <> op.failure_count then begin
          let updated_p = { old_p with
            success_count = op.success_count;
            failure_count = op.failure_count;
            confidence = op.confidence;
            last_applied = op.last_used;
          } in
          procedures := List.map (fun (p : Procedural_memory.procedure) ->
            if p.id = old_p.id then updated_p else p
          ) !procedures;
          needs_rewrite := true;
          true
        end else false
      | None ->
        (* New procedure from OAS -- create in MASC *)
        let new_p : Procedural_memory.procedure = {
          id = op.id;
          agent_name;
          pattern = op.pattern;
          evidence = [];
          success_count = op.success_count;
          failure_count = op.failure_count;
          confidence = op.confidence;
          created_at = Unix.gettimeofday ();
          last_applied = op.last_used;
        } in
        procedures := !procedures @ [new_p];
        needs_rewrite := true;
        true
    in
    if updated then incr flushed
  ) oas_procs;
  if !needs_rewrite then
    Procedural_memory.rewrite_procedures ~agent_name !procedures;
  store_procedures_cache ~agent_name !procedures;
  !flushed

(* ================================================================ *)
(* Pure-read functions for hook-first memory injection               *)
(* (RFC-MASC-004: no side effects, no OAS Memory.t push)            *)
(* ================================================================ *)

(** Load recent episodes as a text block suitable for system context injection.

    Returns [None] when no episodes are available.  The returned string
    is a compact summary — one line per episode — designed to fit inside
    [extra_system_context] without blowing up token count.

    Pure read: does not touch OAS [Memory.t].

    @since v2.265.0 (RFC-MASC-004 Phase 1) *)
let load_episodes_text ~(limit : int) : string option =
  let episodes = cached_recent_episodes ~limit in
  match episodes with
  | [] -> None
  | eps ->
    let lines = List.map (fun (ep : Institution_eio.episode) ->
      Printf.sprintf "- [%s] %s (%s)"
        ep.event_type ep.summary
        (institution_outcome_to_string ep.outcome)
    ) eps in
    Some (Printf.sprintf "[episodic memory: %d episodes]\n%s"
      (List.length eps) (String.concat "\n" lines))

(** Load crystallized procedures as a text block for system context injection.

    Returns [None] when no procedures pass the crystallization threshold.
    Pure read: does not touch OAS [Memory.t].

    @since v2.265.0 (RFC-MASC-004 Phase 1) *)
let load_procedures_text ~(agent_name : string) ~(limit : int) : string option =
  let procs = top_procedures_cached ~agent_name ~limit in
  match procs with
  | [] -> None
  | ps ->
    let lines = List.map (fun (p : Procedural_memory.procedure) ->
      Printf.sprintf "- [%.0f%% confidence] %s" (p.confidence *. 100.0) p.pattern
    ) ps in
    Some (Printf.sprintf "[procedural memory: %d procedures]\n%s"
      (List.length ps) (String.concat "\n" lines))

(** Load institutional memory as a text block for system context injection.

    Returns [None] when no institution config is available.
    Pure read: does not touch OAS [Memory.t].

    @since v2.265.0 (RFC-MASC-004 Phase 1) *)
let load_institution_text ~(config : Room_utils.config) : string option =
  Option.map
    (fun w -> Printf.sprintf "[institutional memory]\n%s" w)
    (read_institution_welcome config)

(** Incrementally flush episodes and procedures.

    Designed to be called from an [AfterTurn] hook on every turn boundary.
    JSONL append-only semantics make repeated calls idempotent —
    already-persisted entries are skipped via ID check.

    @since v2.265.0 (RFC-MASC-004 Phase 1) *)
let flush_incremental ~(memory : Agent_sdk.Memory.t) ~(agent_name : string)
    : int * int =
  (* Reuse existing flush logic which is already incremental
     (skips persisted episode IDs, only writes changed procedures). *)
  let ep = flush_episodes ~memory ~agent_name in
  let pr = flush_procedures ~memory ~agent_name in
  (ep, pr)

