(** Memory_oas_bridge — Connect MASC memory systems to OAS Memory.t 5-tier.

    Tier mapping:
    - {b Long_term} — PostgreSQL via [Memory_pg] when MASC_POSTGRES_URL is set;
                        no-op stubs otherwise
    - {b Episodic}  — no-op (Memory_stream removed)
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

(** No-op long_term_backend stubs for when PostgreSQL is unavailable. *)
let noop_backend : Agent_sdk.Memory.long_term_backend =
  {
    Agent_sdk.Memory.persist = (fun ~key:_ _json -> Ok ());
    retrieve = (fun ~key:_ -> None);
    remove = (fun ~key:_ -> Ok ());
    batch_persist = (fun _pairs -> Ok ());
    query = (fun ~prefix:_ ~limit:_ -> []);
  }

(** Create an OAS [long_term_backend].

    If a PG pool is available (via [Board_dispatch.get_pg_pool]),
    uses [Memory_pg] for persistent storage scoped by [agent_name].
    Otherwise falls back to no-op stubs. *)
let make_backend ~(agent_name : string) : Agent_sdk.Memory.long_term_backend =
  match Board_dispatch.get_pg_pool () with
  | Some pool -> Memory_pg.make_backend ~pool ~agent_name
  | None -> noop_backend

(** Create an OAS [Memory.t] instance.

    Uses PostgreSQL long_term_backend when available, no-op stubs otherwise. *)
let create_memory ~(agent_name : string) : Agent_sdk.Memory.t =
  let backend = make_backend ~agent_name in
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

(** Pre-seed the keeper's memory bank.

    No-op: Memory_stream has been removed.
    Returns 0 (no entries seeded). *)
let seed_memory_bank ~(memory : Agent_sdk.Memory.t) ~(agent_name : string) ~(limit : int) : int =
  ignore (memory, agent_name, limit);
  0

(* ================================================================ *)
(* Episodic tier: no-op (Memory_stream removed)                      *)
(* ================================================================ *)

(** Pre-seed the Episodic tier.

    No-op: Memory_stream has been removed.
    Returns 0 (no episodes seeded). *)
let seed_episodes ~(memory : Agent_sdk.Memory.t) ~(agent_name : string)
    ~(limit : int) : int =
  ignore (memory, agent_name, limit);
  0

(** Flush new OAS episodes.

    No-op: Memory_stream has been removed.
    Returns 0 (no episodes flushed). *)
let flush_episodes ~(memory : Agent_sdk.Memory.t) ~(agent_name : string) : int =
  ignore (memory, agent_name);
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
    - Episodic: no-op (Memory_stream removed)
    - Procedural: top [procedure_limit] crystallized procedures
    - Working/Scratchpad: empty (managed by OAS at runtime)

    Optionally seeds institution to Long_term if [config] is provided.

    @param episode_limit default 50 (currently unused, kept for API compat)
    @param procedure_limit default 20 *)
let create_memory_full ~(agent_name : string)
    ?(config : Room_utils.config option)
    ?(episode_limit = 50) ?(procedure_limit = 20)
    () : Agent_sdk.Memory.t =
  ignore episode_limit;
  let memory = create_memory ~agent_name in
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
    Episodes are no longer flushed (Memory_stream removed).
    Returns [(episodes_flushed, procedures_flushed)]. *)
let flush_all ~(memory : Agent_sdk.Memory.t) ~(agent_name : string)
    : int * int =
  let ep = flush_episodes ~memory ~agent_name in
  let pr = flush_procedures ~memory ~agent_name in
  (ep, pr)
