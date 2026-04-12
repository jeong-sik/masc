(** Memory_oas_bridge — MASC-side adapter that projects product memory into
    OAS Memory.t 5-tier primitives.

    Tier mapping:
    - {b Long_term} — JSONL files under [.masc/memory/<agent>/<session>.jsonl]
    - {b Episodic}  — [seed_episodes] loads recent [Institution_eio] JSONL
                       episodes and [flush_episodes] writes new OAS episodes back
    - {b Procedural} — [seed_procedures_as_oas] loads [Procedural_memory] entries;
                        [flush_procedures] writes back
    - {b Working/Scratchpad} — managed by OAS in-memory; no backend needed

    OAS stays generic here: this module chooses how MASC institutional,
    episodic, and procedural stores seed/flush the SDK memory runtime.

    Filesystem-first policy: Long_term always uses JSONL, regardless of
    whether a PG pool is available.  PG long_term was removed in 2.140.0.

    @since 2.122.0 (long_term only)
    @since 2.124.0 (5-tier: episodic + procedural seeding/flushing)
    @since 2.140.0 (filesystem-first: JSONL long_term_backend always) *)

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
   meaning all concurrent [seed_episodes] / [persisted_episode_ids]
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

let cached_recent_episodes ~limit =
  let cache = load_all_episodes_cached () in
  let total = List.length cache.episodes in
  if total <= limit then cache.episodes
  else
    let rec drop n = function
      | [] -> []
      | remaining when n <= 0 -> remaining
      | _ :: rest -> drop (n - 1) rest
    in
    drop (total - limit) cache.episodes

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
            let rec drop n = function
              | [] -> []
              | remaining when n <= 0 -> remaining
              | (ep : Institution_eio.episode) :: rest ->
                  Hashtbl.remove cache.ids ep.id;
                  drop (n - 1) rest
            in
            drop drop_n episodes
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

(** Format institutional memory as a JSON value suitable for
    [Memory.store ~tier:Long_term "institution" value].

    Loads from institution.json if present, returns None otherwise. *)
let institution_as_json (config : Room_utils.config) : Yojson.Safe.t option =
  let welcome = Institution_eio.load_and_format_for_welcome ~fs:() config in
  if welcome = "" then None
  else Some (`String welcome)

(** Pre-seed institutional memory into a [Memory.t] instance.

    Loads institution context and stores it via [Memory.store ~tier:Long_term].
    This makes institutional guidelines available for cross-agent recall and
    future auto-injection hooks.  Returns [true] if institution was seeded. *)
let seed_institution ~(memory : Agent_sdk.Memory.t) ~(config : Room_utils.config) : bool =
  match institution_as_json config with
  | Some json ->
    (match Agent_sdk.Memory.store memory ~tier:Agent_sdk.Memory.Long_term "institution" json with
     | Ok () -> ()
     | Error msg -> Logs.warn (fun m -> m "Failed to store institution memory: %s" msg));
    true
  | None -> false

(** Pre-seed crystallized procedural memory into a [Memory.t] instance.

    Loads top-N procedures (adaptive threshold: standard 3+/70% OR rare 2+/100%)
    and stores as a single Long_term entry.  Returns the number of procedures seeded. *)
let seed_procedures ~(memory : Agent_sdk.Memory.t) ~(agent_name : string) ~(limit : int) : int =
  let procs = top_procedures_cached ~agent_name ~limit in
  if procs = [] then 0
  else begin
    let json = `Assoc [
      ("agent_name", `String agent_name);
      ("procedures", `List (List.map Procedural_memory.to_json procs));
      ("count", `Int (List.length procs));
    ] in
    (match Agent_sdk.Memory.store memory ~tier:Agent_sdk.Memory.Long_term "procedures" json with
    | Ok () -> ()
    | Error msg -> Logs.warn (fun m -> m "Failed to store procedures memory: %s" msg));
    List.length procs
  end

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

let persisted_episode_ids () =
  Hashtbl.copy (load_all_episodes_cached ()).ids

(** Pre-seed the Episodic tier.

    Loads recent institution episodes from JSONL and projects them into
    OAS episodic memory. *)
let seed_episodes ~(memory : Agent_sdk.Memory.t) ~(agent_name : string)
    ~(limit : int) : int =
  ignore agent_name;
  let episodes = cached_recent_episodes ~limit in
  List.iter
    (fun episode ->
      (try Agent_sdk.Memory.store_episode memory (oas_episode_of_institution episode)
       with Eio.Cancel.Cancelled _ as e -> raise e | exn -> Logs.warn (fun m -> m "Failed to store episode memory: %s" (Printexc.to_string exn))))
    episodes;
  List.length episodes

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

(** Pre-seed the Procedural tier from [Procedural_memory].

    Loads crystallized procedures (adaptive threshold: 3+/70% OR 2+/100%)
    and stores them as OAS procedures with confidence tracking.
    Returns the number of procedures seeded. *)
let seed_procedures_as_oas ~(memory : Agent_sdk.Memory.t)
    ~(agent_name : string) ~(limit : int) : int =
  let procs = top_procedures_cached ~agent_name ~limit in
  List.iter (fun p ->
    (try Agent_sdk.Memory.store_procedure memory (oas_procedure_of_masc p)
     with Eio.Cancel.Cancelled _ as e -> raise e | exn -> Logs.warn (fun m -> m "Failed to store procedure memory: %s" (Printexc.to_string exn)))
  ) procs;
  List.length procs

let seed_all_procedures_as_oas ~(memory : Agent_sdk.Memory.t)
    ~(agent_name : string) : int =
  let procs = load_procedures_cached ~agent_name in
  List.iter
    (fun p ->
      try Agent_sdk.Memory.store_procedure memory (oas_procedure_of_masc p)
      with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
        Logs.warn (fun m ->
          m "Failed to store procedure memory: %s" (Printexc.to_string exn)))
    procs;
  List.length procs

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
(* Full 5-tier memory constructor                                    *)
(* ================================================================ *)

(** Create an OAS [Memory.t] with all 5 tiers populated.

    Seeds:
    - Long_term: JSONL files (filesystem-first, PG not used)
    - Episodic: recent institution episodes from JSONL
    - Procedural: top [procedure_limit] crystallized procedures
    - Working/Scratchpad: empty (managed by OAS at runtime)

    Optionally seeds institution to Long_term if [config] is provided.

    @param episode_limit default 50
    @param procedure_limit default 20 *)
let create_memory_full ~(agent_name : string)
    ?(base_dir : string option)
    ?(session_id : string option)
    ?(config : Room_utils.config option)
    ?(episode_limit = 50) ?(procedure_limit = 20)
    ?(global_procedure_limit = 0)
    () : Agent_sdk.Memory.t =
  let base_dir =
    match base_dir with
    | Some _ -> base_dir
    | None -> Some (resolve_base_dir ?config ())
  in
  let memory = create_memory ~agent_name ?base_dir ?session_id () in
  let _episode_count =
    seed_episodes ~memory ~agent_name ~limit:episode_limit
  in
  (* Procedural tier *)
  let _proc_count =
    seed_procedures_as_oas ~memory ~agent_name ~limit:procedure_limit
  in
  (* Global procedures as Long_term JSON (keeper pattern) *)
  if global_procedure_limit > 0 then
    ignore (seed_procedures ~memory ~agent_name:"_global" ~limit:global_procedure_limit);
  (* Optional Long_term seeds *)
  (match config with
   | Some cfg ->
     let _inst = seed_institution ~memory ~config:cfg in
     ()
   | None -> ());
  memory

(** Flush all mutable tiers back to MASC persistent storage.

    Call after [Agent.run] completes to persist updated procedures.
    Returns [(episodes_flushed, procedures_flushed)]. *)
let flush_all ~(memory : Agent_sdk.Memory.t) ~(agent_name : string)
    : int * int =
  let ep = flush_episodes ~memory ~agent_name in
  let pr = flush_procedures ~memory ~agent_name in
  (ep, pr)
