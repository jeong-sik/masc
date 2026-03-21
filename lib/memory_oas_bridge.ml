(** Memory_oas_bridge — Connect MASC memory systems to OAS Memory.t 5-tier.

    Tier mapping:
    - {b Long_term} — PostgreSQL via [Memory_pg] when MASC_POSTGRES_URL is set;
                        no-op stubs otherwise
    - {b Episodic}  — [seed_episodes] loads recent [Institution_eio] JSONL
                       episodes and [flush_episodes] writes new OAS episodes back
    - {b Procedural} — [seed_procedures_as_oas] loads [Procedural_memory] entries;
                        [flush_procedures] writes back
    - {b Working/Scratchpad} — managed by OAS in-memory; no backend needed

    @since 2.122.0 (long_term only)
    @since 2.124.0 (5-tier: episodic + procedural seeding/flushing)
    @since 2.130.0 (PostgreSQL long_term_backend via Memory_pg) *)

(** Default importance for memories stored via OAS Memory.store.
    Configurable via MASC_MEMORY_OAS_DEFAULT_IMPORTANCE. *)
let default_importance () =
  match Sys.getenv_opt "MASC_MEMORY_OAS_DEFAULT_IMPORTANCE" with
  | Some s -> (try max 1 (min 10 (int_of_string s)) with Failure _ -> 5)
  | None -> 5

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

(** Create an OAS [long_term_backend].

    If a PG pool is available (via [Board_dispatch.get_pg_pool]),
    uses [Memory_pg] for persistent storage scoped by [agent_name].
    Otherwise falls back to session-based JSONL files under
    [.masc/memory/<agent_name>/<session_id>.jsonl]. *)
let make_backend ~(agent_name : string) ~(session_id : string)
  : Agent_sdk.Memory.long_term_backend =
  match Board_dispatch.get_pg_pool () with
  | Some pool -> Memory_pg.make_backend ~pool ~agent_name
  | None ->
    let base_dir = Env_config.me_root () ^ "/.masc" in
    Log.MemoryJsonl.info "Using JSONL fallback for %s (session=%s)"
      agent_name session_id;
    Memory_jsonl.make_backend ~base_dir ~agent_name ~session_id

(** Create an OAS [Memory.t] instance.

    Uses PostgreSQL long_term_backend when available, JSONL fallback otherwise.
    @param session_id Session identifier; defaults to timestamp-based ID. *)
let create_memory ~(agent_name : string) ?(session_id : string option)
    () : Agent_sdk.Memory.t =
  let sid = match session_id with
    | Some s -> s
    | None -> generate_session_id ()
  in
  let backend = make_backend ~agent_name ~session_id:sid in
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
    Agent_sdk.Memory.store memory ~tier:Agent_sdk.Memory.Long_term "institution" json;
    true
  | None -> false

(** Pre-seed crystallized procedural memory into a [Memory.t] instance.

    Loads top-N procedures (adaptive threshold: standard 3+/70% OR rare 2+/100%)
    and stores as a single Long_term entry.  Returns the number of procedures seeded. *)
let seed_procedures ~(memory : Agent_sdk.Memory.t) ~(agent_name : string) ~(limit : int) : int =
  let procs = Procedural_memory.top_procedures ~agent_name ~limit in
  if procs = [] then 0
  else begin
    let json = `Assoc [
      ("agent_name", `String agent_name);
      ("procedures", `List (List.map Procedural_memory.to_json procs));
      ("count", `Int (List.length procs));
    ] in
    Agent_sdk.Memory.store memory ~tier:Agent_sdk.Memory.Long_term "procedures" json;
    List.length procs
  end

(** Legacy keeper memory-bank adapter.

    Historical call sites still invoke this helper, but the current 5-tier path
    seeds episodic memory through [seed_episodes]. The removed Memory_stream
    backend is not revived here, so this remains an intentional no-op.
    Returns 0 to preserve legacy callers. *)
let seed_memory_bank ~(memory : Agent_sdk.Memory.t) ~(agent_name : string) ~(limit : int) : int =
  ignore (memory, agent_name, limit);
  0

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
  Institution_eio.load_recent_episodes_jsonl ~limit:max_int
  |> List.fold_left
       (fun seen (episode : Institution_eio.episode) ->
         if List.mem episode.id seen then seen else episode.id :: seen)
       []

(** Pre-seed the Episodic tier.

    Loads recent institution episodes from JSONL and projects them into
    OAS episodic memory. *)
let seed_episodes ~(memory : Agent_sdk.Memory.t) ~(agent_name : string)
    ~(limit : int) : int =
  ignore agent_name;
  let episodes = Institution_eio.load_recent_episodes_jsonl ~limit in
  List.iter
    (fun episode ->
      Agent_sdk.Memory.store_episode memory (oas_episode_of_institution episode))
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
         if List.mem episode.id persisted_ids then flushed
         else (
           Fs_compat.append_jsonl path
             (Institution_eio.episode_to_json
                (institution_episode_of_oas ~agent_name episode));
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
  let procs = Procedural_memory.top_procedures ~agent_name ~limit in
  List.iter (fun p ->
    Agent_sdk.Memory.store_procedure memory (oas_procedure_of_masc p)
  ) procs;
  List.length procs

(** Flush OAS procedures back to [Procedural_memory].

    Extracts procedures from the Procedural tier that have been updated
    (new success/failure counts) and persists them.
    Returns the number of procedures flushed. *)
let flush_procedures ~(memory : Agent_sdk.Memory.t) ~(agent_name : string) : int =
  let oas_procs =
    Agent_sdk.Memory.matching_procedures memory
      ~pattern:"" ()
  in
  let flushed = ref 0 in
  List.iter (fun (op : Agent_sdk.Memory.procedure) ->
    let existing = Procedural_memory.load_procedures ~agent_name in
    let updated =
      match List.find_opt (fun (p : Procedural_memory.procedure) ->
        p.id = op.id
      ) existing with
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
          Procedural_memory.save_procedure ~agent_name updated_p;
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
        Procedural_memory.save_procedure ~agent_name new_p;
        true
    in
    if updated then incr flushed
  ) oas_procs;
  !flushed

(* ================================================================ *)
(* Full 5-tier memory constructor                                    *)
(* ================================================================ *)

(** Create an OAS [Memory.t] with all 5 tiers populated.

    Seeds:
    - Long_term: PostgreSQL via [Memory_pg] when available, no-op stubs otherwise
    - Episodic: recent institution episodes from JSONL
    - Procedural: top [procedure_limit] crystallized procedures
    - Working/Scratchpad: empty (managed by OAS at runtime)

    Optionally seeds institution to Long_term if [config] is provided.

    @param episode_limit default 50
    @param procedure_limit default 20 *)
let create_memory_full ~(agent_name : string)
    ?(session_id : string option)
    ?(config : Room_utils.config option)
    ?(episode_limit = 50) ?(procedure_limit = 20)
    () : Agent_sdk.Memory.t =
  let memory = create_memory ~agent_name ?session_id () in
  let _episode_count =
    seed_episodes ~memory ~agent_name ~limit:episode_limit
  in
  (* Procedural tier *)
  let _proc_count =
    seed_procedures_as_oas ~memory ~agent_name ~limit:procedure_limit
  in
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
