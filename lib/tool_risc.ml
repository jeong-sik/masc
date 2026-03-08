(** Tool_risc -- MCP Tool Handlers for SWARM-RISC Pipeline + Cache Coherence

    Exposes pipeline operations and cache coherence as MCP tools.
    Phase 1 tools: pipeline_status, decode, pipeline_flush.
    Phase 2 tools: cache_status, cache_read, cache_write, cache_metrics.

    Tool dispatch follows the project convention: match-based routing,
    no dict/map lookup.

    @since 2.78.0 *)

open Risc_types
open Risc_pipeline

(* ================================================================ *)
(* Global Pipeline Registry                                         *)
(* ================================================================ *)

(** Singleton pipeline registry shared across all tool calls. *)
let global_registry = create_registry ()

(* ================================================================ *)
(* Global Coherence Controller (Phase 2)                            *)
(* ================================================================ *)

(** Singleton MESI coherence controller shared across all cache tools. *)
let global_coherence = Cache_coherence.create_controller ()

(* ================================================================ *)
(* Argument Helpers (consistent with tool_cache.ml pattern)         *)
(* ================================================================ *)

let get_string args key default =
  match args with
  | `Assoc fields ->
      (match List.assoc_opt key fields with
       | Some (`String s) -> s
       | _ -> default)
  | _ -> default

let get_string_opt args key =
  match args with
  | `Assoc fields ->
      (match List.assoc_opt key fields with
       | Some (`String s) when s <> "" -> Some s
       | _ -> None)
  | _ -> None

let get_string_list args key =
  match args with
  | `Assoc fields ->
      (match List.assoc_opt key fields with
       | Some (`List lst) ->
           List.filter_map (function `String s -> Some s | _ -> None) lst
       | _ -> [])
  | _ -> []

let get_int args key default =
  match args with
  | `Assoc fields ->
      (match List.assoc_opt key fields with
       | Some (`Int i) -> i
       | _ -> default)
  | _ -> default

(* ================================================================ *)
(* Tool Result Type                                                 *)
(* ================================================================ *)

type result = bool * string

(* ================================================================ *)
(* Tool: masc_risc_pipeline_status                                  *)
(* ================================================================ *)

(** Query pipeline stage occupancy and metrics for all agents
    or a specific agent.

    Arguments:
    - agent_id (optional): filter to specific agent

    Returns: pipeline state, metrics, occupancy. *)
let handle_pipeline_status args : result =
  let agent_id = get_string_opt args "agent_id" in
  match agent_id with
  | Some id ->
      (match get_pipeline global_registry id with
       | Some p ->
           (true, Yojson.Safe.pretty_to_string (agent_pipeline_to_yojson p))
       | None ->
           (false, Printf.sprintf "Agent %s not found in pipeline registry" id))
  | None ->
      let status = registry_status global_registry in
      (true, Yojson.Safe.pretty_to_string status)

(* ================================================================ *)
(* Tool: masc_risc_decode                                           *)
(* ================================================================ *)

(** Decode a task into a dependency graph of micro-ops.

    Arguments:
    - task_id: task to decompose
    - instructions: list of instruction specs (simplified JSON format)

    For Phase 1, instructions are parsed from a simplified JSON
    representation. Future phases use LLM-assisted decomposition.

    Returns: list of micro-ops with dependency edges. *)
let parse_instruction (json : Yojson.Safe.t) : instruction option =
  let module U = Yojson.Safe.Util in
  try
    let mnemonic = json |> U.member "mnemonic" |> U.to_string in
    match String.uppercase_ascii mnemonic with
    | "FETCH" ->
        let task_spec = json |> U.member "task_spec" |> U.to_string in
        let priority_val = try json |> U.member "priority" |> U.to_int
          with _ -> 3 in
        Some (FETCH { task_spec; priority = priority_of_int priority_val })
    | "DECODE" ->
        let task_id = json |> U.member "task_id" |> U.to_string in
        Some (DECODE { task_id })
    | "EXEC" ->
        let op_id = json |> U.member "op_id" |> U.to_string in
        let tool = json |> U.member "tool" |> U.to_string in
        let args = try json |> U.member "args" with _ -> `Null in
        Some (EXEC { op_id; tool; args })
    | "STORE" ->
        let key = json |> U.member "key" |> U.to_string in
        let value = json |> U.member "value" in
        let scope_str = try json |> U.member "scope" |> U.to_string
          with _ -> "L2" in
        let scope = match cache_scope_of_string scope_str with
          | Ok s -> s | Error _ -> L2_room in
        Some (STORE { key; value; scope })
    | "LOAD" ->
        let key = json |> U.member "key" |> U.to_string in
        let scope_str = try json |> U.member "scope" |> U.to_string
          with _ -> "L2" in
        let scope = match cache_scope_of_string scope_str with
          | Ok s -> s | Error _ -> L2_room in
        Some (LOAD { key; scope })
    | "BRANCH" ->
        let condition = json |> U.member "condition" |> U.to_string in
        let target_a = json |> U.member "target_a" |> U.to_string in
        let target_b = json |> U.member "target_b" |> U.to_string in
        Some (BRANCH { condition; target_a; target_b })
    | "SPEC" ->
        let op_id = json |> U.member "op_id" |> U.to_string in
        let model_str = try json |> U.member "model" |> U.to_string
          with _ -> "fast_local" in
        let model = match model_str with
          | "fast_cloud" -> Fast_cloud
          | _ -> Fast_local in
        Some (SPEC { model; op_id })
    | "COMMIT" ->
        let spec_id = json |> U.member "spec_id" |> U.to_string in
        Some (COMMIT { spec_id })
    | "ABORT" ->
        let spec_id = json |> U.member "spec_id" |> U.to_string in
        Some (ABORT { spec_id })
    | "SYNC" ->
        let barrier_id = json |> U.member "barrier_id" |> U.to_string in
        let agents = try
          json |> U.member "agents" |> U.to_list |> List.map U.to_string
          with _ -> [] in
        Some (SYNC { barrier_id; agents })
    | "YIELD" ->
        let reason = json |> U.member "reason" |> U.to_string in
        Some (YIELD { reason })
    | "HALT" ->
        let exit_code = try json |> U.member "exit_code" |> U.to_int
          with _ -> 0 in
        let dna = try
          let d = json |> U.member "dna" in
          if d = `Null then None else Some d
          with _ -> None in
        Some (HALT { exit_code; dna })
    | _ -> None
  with _ -> None

let handle_decode args : result =
  let task_id = get_string args "task_id" "" in
  if task_id = "" then
    (false, "task_id is required")
  else
    let instructions_json = match args with
      | `Assoc fields ->
          (match List.assoc_opt "instructions" fields with
           | Some (`List lst) -> lst
           | _ -> [])
      | _ -> []
    in
    let instructions = List.filter_map parse_instruction instructions_json in
    if instructions = [] then
      (false, "No valid instructions provided")
    else
      let micro_ops = decode_task ~task_id ~instructions in
      let ops_json = List.map micro_op_to_yojson micro_ops in
      (true, Yojson.Safe.pretty_to_string (`Assoc [
        ("task_id", `String task_id);
        ("micro_op_count", `Int (List.length micro_ops));
        ("micro_ops", `List ops_json);
      ]))

(* ================================================================ *)
(* Tool: masc_risc_pipeline_advance                                 *)
(* ================================================================ *)

(** Advance the pipeline for a specific agent by one cycle.

    Arguments:
    - agent_id: which agent's pipeline to advance
    - pending_ops (optional): new micro-ops to insert

    Returns: advance result including completed ops and hazards. *)
let handle_pipeline_advance args : result =
  let agent_id = get_string args "agent_id" "" in
  if agent_id = "" then
    (false, "agent_id is required")
  else begin
    (* Ensure agent is registered *)
    register_agent global_registry agent_id;
    match get_pipeline global_registry agent_id with
    | None ->
        (false, Printf.sprintf "Agent %s pipeline not found" agent_id)
    | Some pipeline ->
        (* Parse pending ops from args *)
        let pending_json = match args with
          | `Assoc fields ->
              (match List.assoc_opt "pending_ops" fields with
               | Some (`List lst) -> lst
               | _ -> [])
          | _ -> []
        in
        let pending_instructions = List.filter_map parse_instruction pending_json in
        let pending_ops = List.map (fun instr ->
          let id = generate_op_id ~task_id:agent_id in
          {
            id;
            parent_task_id = agent_id;
            instruction = instr;
            stage = Stage_fetch;
            issued_at = Unix.gettimeofday ();
            dependencies = [];
            result = None;
          }
        ) pending_instructions in
        (* Collect already-completed op IDs from metrics *)
        let completed_ids = [] in  (* Phase 1: no forwarding *)
        let result = advance ~completed_ids ~pending_ops pipeline in
        update_pipeline global_registry agent_id result.pipeline;
        let result_json = `Assoc [
          ("agent_id", `String agent_id);
          ("cycle", `Int global_registry.global_cycle);
          ("completed", `List (List.map micro_op_to_yojson result.completed));
          ("hazards", `List (List.map hazard_to_yojson result.hazards));
          ("stalled", `Bool result.stalled);
          ("pipeline", agent_pipeline_to_yojson result.pipeline);
        ] in
        (true, Yojson.Safe.pretty_to_string result_json)
  end

(* ================================================================ *)
(* Tool: masc_risc_pipeline_flush                                   *)
(* ================================================================ *)

(** Flush an agent's pipeline (discard all in-flight ops).

    Arguments:
    - agent_id: which agent's pipeline to flush

    Returns: success status. *)
let handle_pipeline_flush args : result =
  let agent_id = get_string args "agent_id" "" in
  if agent_id = "" then
    (false, "agent_id is required")
  else if flush_pipeline global_registry agent_id then
    (true, Printf.sprintf "Pipeline flushed for agent %s" agent_id)
  else
    (false, Printf.sprintf "Agent %s not found in pipeline registry" agent_id)

(* ================================================================ *)
(* Tool: masc_risc_register_agent                                   *)
(* ================================================================ *)

(** Register an agent in the pipeline system.

    Arguments:
    - agent_id: agent to register

    Returns: confirmation. *)
let handle_register_agent args : result =
  let agent_id = get_string args "agent_id" "" in
  if agent_id = "" then
    (false, "agent_id is required")
  else begin
    register_agent global_registry agent_id;
    (true, Printf.sprintf "Agent %s registered in pipeline" agent_id)
  end

(* ================================================================ *)
(* Tool: masc_risc_metrics                                          *)
(* ================================================================ *)

(** Get aggregate pipeline metrics.

    Returns: total_ops, completed_ops, IPC, stall rate, etc. *)
let handle_metrics _args : result =
  let m = aggregate_metrics global_registry in
  let stall_rate =
    if m.total_ops = 0 then 0.0
    else float_of_int m.stalled_cycles /. float_of_int m.total_ops
  in
  let json = `Assoc [
    ("aggregate", metrics_to_yojson m);
    ("stall_rate", `Float stall_rate);
    ("global_cycle", `Int global_registry.global_cycle);
    ("registered_agents", `Int (Hashtbl.length global_registry.pipelines));
  ] in
  (true, Yojson.Safe.pretty_to_string json)

(* ================================================================ *)
(* Tool: masc_risc_cache_status (Phase 2)                          *)
(* ================================================================ *)

(** Query MESI cache coherence state.
    - No args: aggregate metrics across all agents
    - agent_id only: list all non-Invalid L1 lines for that agent
    - agent_id + key: specific line MESI state *)
let handle_cache_status args : result =
  let agent_id = get_string_opt args "agent_id" in
  let key = get_string_opt args "key" in
  match agent_id, key with
  | Some aid, Some k ->
      (match Cache_coherence.get_line_state global_coherence ~agent_id:aid ~key:k with
       | Some state ->
           (true, Yojson.Safe.pretty_to_string (`Assoc [
             ("agent_id", `String aid);
             ("key", `String k);
             ("state", Cache_coherence.mesi_to_yojson state);
           ]))
       | None ->
           (false, Printf.sprintf "Agent %s not registered in coherence controller" aid))
  | Some aid, None ->
      let lines = Cache_coherence.list_lines global_coherence ~agent_id:aid in
      let lines_json = List.map Cache_coherence.line_to_yojson lines in
      (true, Yojson.Safe.pretty_to_string (`Assoc [
        ("agent_id", `String aid);
        ("line_count", `Int (List.length lines));
        ("lines", `List lines_json);
      ]))
  | None, _ ->
      let metrics = Cache_coherence.aggregate_metrics global_coherence in
      (true, Yojson.Safe.pretty_to_string (`Assoc [
        ("aggregate_metrics", Cache_coherence.metrics_to_yojson metrics);
        ("registered_agents", `Int (Hashtbl.length global_coherence.Cache_coherence.agents));
      ]))

(* ================================================================ *)
(* Tool: masc_risc_cache_read (Phase 2)                            *)
(* ================================================================ *)

(** Coherent read through MESI L1 cache.
    L1 hit returns cached value; L1 miss probes L2 (stub for now). *)
let handle_cache_read args : result =
  let agent_id = get_string args "agent_id" "" in
  let key = get_string args "key" "" in
  if agent_id = "" then (false, "agent_id is required")
  else if key = "" then (false, "key is required")
  else begin
    Cache_coherence.register_agent global_coherence agent_id;
    (* L2 fetch stub — future: wire to cache_eio.ml file-based cache *)
    let l2_fetch _k = None in
    match Cache_coherence.coherent_read global_coherence ~agent_id ~key ~l2_fetch with
    | Some value ->
        (true, Yojson.Safe.pretty_to_string (`Assoc [
          ("agent_id", `String agent_id);
          ("key", `String key);
          ("value", `String value);
          ("source", `String "L1_hit");
        ]))
    | None ->
        (true, Yojson.Safe.pretty_to_string (`Assoc [
          ("agent_id", `String agent_id);
          ("key", `String key);
          ("value", `Null);
          ("source", `String "miss");
        ]))
  end

(* ================================================================ *)
(* Tool: masc_risc_cache_write (Phase 2)                           *)
(* ================================================================ *)

(** Coherent write through MESI L1 cache.
    Updates L1, broadcasts invalidation to other agents, write-through to L2. *)
let handle_cache_write args : result =
  let agent_id = get_string args "agent_id" "" in
  let key = get_string args "key" "" in
  let value = get_string args "value" "" in
  if agent_id = "" then (false, "agent_id is required")
  else if key = "" then (false, "key is required")
  else begin
    Cache_coherence.register_agent global_coherence agent_id;
    (* L2 write stub — future: wire to cache_eio.ml *)
    let l2_write _k _v = () in
    Cache_coherence.coherent_write global_coherence ~agent_id ~key ~value ~l2_write;
    let state = Cache_coherence.get_line_state global_coherence ~agent_id ~key in
    let state_json = match state with
      | Some s -> Cache_coherence.mesi_to_yojson s
      | None -> `String "unknown"
    in
    (true, Yojson.Safe.pretty_to_string (`Assoc [
      ("agent_id", `String agent_id);
      ("key", `String key);
      ("state", state_json);
      ("written", `Bool true);
    ]))
  end

(* ================================================================ *)
(* Tool: masc_risc_cache_metrics (Phase 2)                         *)
(* ================================================================ *)

(** Get cache coherence metrics — per-agent or aggregate.
    Returns hit rate, invalidation count, writeback count, bus traffic. *)
let handle_cache_metrics args : result =
  let agent_id = get_string_opt args "agent_id" in
  match agent_id with
  | Some aid ->
      (match Cache_coherence.agent_metrics global_coherence aid with
       | Some m ->
           (true, Yojson.Safe.pretty_to_string (`Assoc [
             ("agent_id", `String aid);
             ("metrics", Cache_coherence.metrics_to_yojson m);
           ]))
       | None ->
           (false, Printf.sprintf "Agent %s not registered in coherence controller" aid))
  | None ->
      let m = Cache_coherence.aggregate_metrics global_coherence in
      (true, Yojson.Safe.pretty_to_string (`Assoc [
        ("aggregate", Cache_coherence.metrics_to_yojson m);
        ("registered_agents", `Int (Hashtbl.length global_coherence.Cache_coherence.agents));
      ]))

(* ================================================================ *)
(* Tool Definitions (for MCP registration)                          *)
(* ================================================================ *)

(** MCP tool definitions for SWARM-RISC Phase 1 + Phase 2.
    To be registered in mcp_server_eio.ml dispatch. *)
let tool_definitions : (string * Yojson.Safe.t) list = [
  ("masc_risc_pipeline_status", `Assoc [
    ("name", `String "masc_risc_pipeline_status");
    ("description", `String "Query RISC pipeline status: stage occupancy, metrics, hazards. Optionally filter by agent_id.");
    ("inputSchema", `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("agent_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Filter to specific agent (optional)")
        ]);
      ]);
    ]);
  ]);

  ("masc_risc_decode", `Assoc [
    ("name", `String "masc_risc_decode");
    ("description", `String "Decode a task into dependency graph of micro-ops. Provide task_id and list of instructions.");
    ("inputSchema", `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("task_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Task ID to decompose")
        ]);
        ("instructions", `Assoc [
          ("type", `String "array");
          ("description", `String "List of instruction objects with mnemonic and operands");
          ("items", `Assoc [("type", `String "object")]);
        ]);
      ]);
      ("required", `List [`String "task_id"; `String "instructions"]);
    ]);
  ]);

  ("masc_risc_pipeline_advance", `Assoc [
    ("name", `String "masc_risc_pipeline_advance");
    ("description", `String "Advance an agent's RISC pipeline by one cycle. Optionally inject new micro-ops.");
    ("inputSchema", `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("agent_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Agent whose pipeline to advance")
        ]);
        ("pending_ops", `Assoc [
          ("type", `String "array");
          ("description", `String "New instructions to inject (optional)");
          ("items", `Assoc [("type", `String "object")]);
        ]);
      ]);
      ("required", `List [`String "agent_id"]);
    ]);
  ]);

  ("masc_risc_pipeline_flush", `Assoc [
    ("name", `String "masc_risc_pipeline_flush");
    ("description", `String "Flush an agent's pipeline, discarding all in-flight operations.");
    ("inputSchema", `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("agent_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Agent whose pipeline to flush")
        ]);
      ]);
      ("required", `List [`String "agent_id"]);
    ]);
  ]);

  ("masc_risc_register_agent", `Assoc [
    ("name", `String "masc_risc_register_agent");
    ("description", `String "Register an agent in the RISC pipeline system.");
    ("inputSchema", `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("agent_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Agent ID to register")
        ]);
      ]);
      ("required", `List [`String "agent_id"]);
    ]);
  ]);

  ("masc_risc_metrics", `Assoc [
    ("name", `String "masc_risc_metrics");
    ("description", `String "Get aggregate RISC pipeline metrics: IPC, stall rate, hazard count.");
    ("inputSchema", `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ]);
  ]);

  (* Phase 2: Cache Coherence tools *)

  ("masc_risc_cache_status", `Assoc [
    ("name", `String "masc_risc_cache_status");
    ("description", `String "Query MESI cache coherence state. No args: aggregate. agent_id: list lines. agent_id+key: specific line state.");
    ("inputSchema", `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("agent_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Agent whose L1 cache to query (optional)")
        ]);
        ("key", `Assoc [
          ("type", `String "string");
          ("description", `String "Cache key to query MESI state (optional, requires agent_id)")
        ]);
      ]);
    ]);
  ]);

  ("masc_risc_cache_read", `Assoc [
    ("name", `String "masc_risc_cache_read");
    ("description", `String "Coherent read through MESI L1 cache. L1 hit returns cached value, miss probes L2.");
    ("inputSchema", `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("agent_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Agent performing the read")
        ]);
        ("key", `Assoc [
          ("type", `String "string");
          ("description", `String "Cache key to read")
        ]);
      ]);
      ("required", `List [`String "agent_id"; `String "key"]);
    ]);
  ]);

  ("masc_risc_cache_write", `Assoc [
    ("name", `String "masc_risc_cache_write");
    ("description", `String "Coherent write through MESI L1 cache. Updates L1, invalidates other agents, write-through to L2.");
    ("inputSchema", `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("agent_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Agent performing the write")
        ]);
        ("key", `Assoc [
          ("type", `String "string");
          ("description", `String "Cache key to write")
        ]);
        ("value", `Assoc [
          ("type", `String "string");
          ("description", `String "Value to store")
        ]);
      ]);
      ("required", `List [`String "agent_id"; `String "key"; `String "value"]);
    ]);
  ]);

  ("masc_risc_cache_metrics", `Assoc [
    ("name", `String "masc_risc_cache_metrics");
    ("description", `String "Get cache coherence metrics: hit rate, invalidation count, writeback count, bus traffic.");
    ("inputSchema", `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("agent_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Agent to query (optional, omit for aggregate)")
        ]);
      ]);
    ]);
  ]);
]

(** Tool schemas in Types.tool_schema format for config.ml registration. *)
let schemas : Types.tool_schema list =
  List.map (fun (_name, json) ->
    let open Yojson.Safe.Util in
    { Types.name = json |> member "name" |> to_string;
      description = json |> member "description" |> to_string;
      input_schema = json |> member "inputSchema";
    }
  ) tool_definitions

(** Dispatch a RISC tool call by name. *)
let dispatch tool_name args : result =
  match tool_name with
  (* Phase 1: Pipeline *)
  | "masc_risc_pipeline_status" -> handle_pipeline_status args
  | "masc_risc_decode" -> handle_decode args
  | "masc_risc_pipeline_advance" -> handle_pipeline_advance args
  | "masc_risc_pipeline_flush" -> handle_pipeline_flush args
  | "masc_risc_register_agent" -> handle_register_agent args
  | "masc_risc_metrics" -> handle_metrics args
  (* Phase 2: Cache Coherence *)
  | "masc_risc_cache_status" -> handle_cache_status args
  | "masc_risc_cache_read" -> handle_cache_read args
  | "masc_risc_cache_write" -> handle_cache_write args
  | "masc_risc_cache_metrics" -> handle_cache_metrics args
  | _ -> (false, Printf.sprintf "Unknown RISC tool: %s" tool_name)

(** Check if a tool name is a RISC tool. *)
let is_risc_tool name =
  String.length name > 10
  && String.sub name 0 10 = "masc_risc_"
