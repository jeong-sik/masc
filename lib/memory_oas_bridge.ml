(** Memory_oas_bridge — Connect MASC memory systems to OAS Memory.t 5-tier.

    Tier mapping:
    - {b Long_term} — [long_term_backend] via [Memory_stream] (persist/retrieve/query)
    - {b Episodic}  — [seed_episodes] loads [Memory_stream] entries as OAS episodes;
                       [flush_episodes] writes new episodes back to [Memory_stream]
    - {b Procedural} — [seed_procedures_as_oas] loads [Procedural_memory] entries;
                        [flush_procedures] writes back
    - {b Working/Scratchpad} — managed by OAS in-memory; no backend needed

    Usage:
    {[
      let memory = Memory_oas_bridge.create_memory_full ~agent_name ~config () in
      (* All 5 tiers operational *)
      let _ = Agent_sdk.Memory.recall_episodes memory () in
      let _ = Agent_sdk.Memory.best_procedure memory ~pattern:"deploy" in
    ]}

    @since 2.122.0 (long_term only)
    @since 2.124.0 (5-tier: episodic + procedural seeding/flushing) *)

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

(** Create an OAS [long_term_backend] backed by [Memory_stream] for a
    specific agent.

    Usage:
    {[
      let backend = Memory_oas_bridge.make_backend ~agent_name:"keeper-dm" in
      let memory = Agent_sdk.Memory.create ~long_term:backend () in
      (* Agent.t can now use Memory.store/recall ~tier:Long_term *)
    ]}
*)
let make_backend ~(agent_name : string) : Agent_sdk.Memory.long_term_backend =
  {
    Agent_sdk.Memory.persist = (fun ~key json ->
      let content = Printf.sprintf "[%s] %s" key (content_of_json json) in
      let importance = importance_of_json json in
      Memory_stream.add_memory
        ~agent_name ~content ~importance
        (Memory_stream.Observation content);
      Ok ());

    retrieve = (fun ~key ->
      let entries = Memory_stream.retrieve ~agent_name ~query:key ~limit:1 in
      match entries with
      | entry :: _ ->
        Some (`Assoc [
          ("id", `String entry.Memory_stream.id);
          ("content", `String entry.Memory_stream.content);
          ("importance", `Int entry.Memory_stream.importance);
          ("timestamp", `Float entry.Memory_stream.timestamp);
        ])
      | [] -> None);

    remove = (fun ~key:_ ->
      (* Memory_stream is append-only JSONL. Old entries decay naturally
         via recency scoring. Explicit removal not supported. *)
      Ok ());

    batch_persist = (fun pairs ->
      List.iter (fun (key, json) ->
        let content = Printf.sprintf "[%s] %s" key (content_of_json json) in
        let importance = importance_of_json json in
        Memory_stream.add_memory
          ~agent_name ~content ~importance
          (Memory_stream.Observation content)
      ) pairs;
      Ok ());

    query = (fun ~prefix ~limit ->
      let entries = Memory_stream.retrieve ~agent_name ~query:prefix ~limit in
      List.map (fun (e : Memory_stream.memory_entry) ->
        (e.Memory_stream.id,
         `Assoc [
           ("content", `String e.Memory_stream.content);
           ("importance", `Int e.Memory_stream.importance);
           ("timestamp", `Float e.Memory_stream.timestamp);
         ])
      ) entries);
  }

(** Create an OAS [Memory.t] instance pre-configured with the memory_stream
    backend for a specific agent.

    This is the primary entry point for integrating OAS Memory into MASC
    agent execution paths (gardener workers, keeper, perpetual agents). *)
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

(** Pre-seed the keeper's memory bank (recent observations and reflections)
    into a [Memory.t] instance.

    Loads the last [limit] entries from the agent's memory stream and stores
    them as a single Long_term entry.  Returns the number of entries seeded. *)
let seed_memory_bank ~(memory : Agent_sdk.Memory.t) ~(agent_name : string) ~(limit : int) : int =
  let entries = Memory_stream.retrieve ~agent_name ~query:"*" ~limit in
  if entries = [] then 0
  else begin
    let json = `Assoc [
      ("agent_name", `String agent_name);
      ("entries", `List (List.map (fun (e : Memory_stream.memory_entry) ->
        `Assoc [
          ("id", `String e.id);
          ("content", `String e.content);
          ("importance", `Int e.importance);
          ("timestamp", `Float e.timestamp);
        ]) entries));
      ("count", `Int (List.length entries));
    ] in
    Agent_sdk.Memory.store memory ~tier:Agent_sdk.Memory.Long_term "memory_bank" json;
    List.length entries
  end

(* ================================================================ *)
(* Episodic tier: Memory_stream <-> OAS episodes                    *)
(* ================================================================ *)

(** Convert a [Memory_stream.memory_entry] to an OAS [episode].

    Mapping:
    - [importance] (1-10 int) → [salience] (0.0-1.0 float)
    - [content] → [action]
    - [entry_type] → [outcome]: all mapped to [Neutral] (Memory_stream
      entries are observations, not success/failure outcomes)
    - [agent_name] → [participants] singleton list *)
let episode_of_entry (e : Memory_stream.memory_entry) : Agent_sdk.Memory.episode =
  {
    id = e.id;
    timestamp = e.timestamp;
    participants = [ e.agent_name ];
    action = e.content;
    outcome = Agent_sdk.Memory.Neutral;
    salience = Float.min 1.0 (Float.max 0.0
      (Float.of_int e.importance /. 10.0));
    metadata =
      (match e.links with
       | [] -> []
       | links ->
         [ ("links", `List (List.map (fun s -> `String s) links)) ]);
  }

(** Pre-seed the Episodic tier from [Memory_stream].

    Loads recent entries and stores them as OAS episodes with salience
    derived from importance scores.  OAS handles time-decay via
    [recall_episodes ~decay_rate].  Returns the number of episodes seeded. *)
let seed_episodes ~(memory : Agent_sdk.Memory.t) ~(agent_name : string)
    ~(limit : int) : int =
  let entries = Memory_stream.retrieve ~agent_name ~query:"*" ~limit in
  List.iter (fun e ->
    Agent_sdk.Memory.store_episode memory (episode_of_entry e)
  ) entries;
  List.length entries

(** Flush new OAS episodes back to [Memory_stream].

    Extracts episodes from the Episodic tier (above [min_salience]) and
    persists any that do not already exist in [Memory_stream].
    Returns the number of new episodes flushed. *)
let flush_episodes ~(memory : Agent_sdk.Memory.t) ~(agent_name : string) : int =
  let episodes =
    Agent_sdk.Memory.recall_episodes memory
      ~min_salience:0.1 ~limit:100 ()
  in
  let flushed = ref 0 in
  List.iter (fun (ep : Agent_sdk.Memory.episode) ->
    (* Only flush episodes created during the session (not pre-seeded).
       Pre-seeded episodes have IDs from Memory_stream, which have a
       known format.  New episodes have IDs assigned by OAS. *)
    let existing = Memory_stream.retrieve ~agent_name ~query:ep.id ~limit:1 in
    if existing = [] then begin
      let importance =
        Float.to_int (Float.round (ep.salience *. 10.0))
        |> max 1 |> min 10
      in
      Memory_stream.add_memory
        ~agent_name ~content:ep.action ~importance
        (Memory_stream.Observation ep.action);
      incr flushed
    end
  ) episodes;
  !flushed

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
        (* New procedure from OAS — create in MASC *)
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
    - Long_term: [long_term_backend] via [Memory_stream]
    - Episodic: last [episode_limit] entries from [Memory_stream]
    - Procedural: top [procedure_limit] crystallized procedures
    - Working/Scratchpad: empty (managed by OAS at runtime)

    Optionally seeds institution and memory bank to Long_term if
    [config] is provided.

    @param episode_limit default 50
    @param procedure_limit default 20 *)
let create_memory_full ~(agent_name : string)
    ?(config : Room_utils.config option)
    ?(episode_limit = 50) ?(procedure_limit = 20)
    () : Agent_sdk.Memory.t =
  let memory = create_memory ~agent_name in
  (* Episodic tier *)
  let _ep_count = seed_episodes ~memory ~agent_name ~limit:episode_limit in
  (* Procedural tier *)
  let _proc_count =
    seed_procedures_as_oas ~memory ~agent_name ~limit:procedure_limit
  in
  (* Optional Long_term seeds *)
  (match config with
   | Some cfg ->
     let _inst = seed_institution ~memory ~config:cfg in
     let _bank = seed_memory_bank ~memory ~agent_name ~limit:20 in
     ()
   | None -> ());
  memory

(** Flush all mutable tiers back to MASC persistent storage.

    Call after [Agent.run] completes to persist new episodes and
    updated procedures.  Returns [(episodes_flushed, procedures_flushed)]. *)
let flush_all ~(memory : Agent_sdk.Memory.t) ~(agent_name : string)
    : int * int =
  let ep = flush_episodes ~memory ~agent_name in
  let pr = flush_procedures ~memory ~agent_name in
  (ep, pr)
