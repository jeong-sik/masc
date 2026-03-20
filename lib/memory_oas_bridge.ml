(** Memory_oas_bridge — Connect MASC memory systems to OAS Memory.t.

    Implements [Agent_sdk.Memory.long_term_backend] using MASC's
    [Memory_stream] and [Institution_eio] as the persistence layer.

    This bridge allows OAS Agent.t to use [Memory.store ~tier:Long_term]
    and [Memory.recall ~tier:Long_term] transparently, with MASC's
    existing JSONL-based memory stream handling the actual persistence.

    Key mapping:
    - [persist ~key json] → [Memory_stream.add_memory] (importance from JSON or default 5)
    - [retrieve ~key] → [Memory_stream.retrieve] with key as query (top-1)
    - [remove ~key] → no-op (JSONL is append-only, entries decay via scoring)

    @since 2.122.0 *)

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
        (Memory_stream.Observation content));

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
      ());
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
