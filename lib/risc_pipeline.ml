(** SWARM-RISC Pipeline -- 5-Stage Agent Instruction Pipeline

    Implements the core pipeline: Fetch -> Decode -> Schedule -> Execute -> Writeback.

    This is the in-order pipeline (Phase 1). Out-of-order execution via
    Tomasulo reservation stations is Phase 3.

    Pipeline hazards are detected but resolved by stalling (Phase 1).
    Forwarding and bypassing are Phase 3 enhancements.

    The pipeline is per-agent: each agent has its own pipeline state.
    A global pipeline registry tracks all active agent pipelines.

    @since 2.78.0 *)

open Risc_types

(* ================================================================ *)
(* Micro-op ID generation                                           *)
(* ================================================================ *)

let micro_op_counter = Atomic.make 0

let generate_op_id ~task_id =
  let seq = Atomic.fetch_and_add micro_op_counter 1 in
  Printf.sprintf "uop-%s-%04d" task_id seq

(* ================================================================ *)
(* Dependency analysis (DECODE stage logic)                         *)
(* ================================================================ *)

(** Decompose a task into a list of micro-ops with dependency edges.

    For Phase 1, decomposition is straightforward:
    - Single-instruction tasks produce 1 micro-op
    - Multi-step tasks are split at tool boundaries

    Future: LLM-assisted decomposition for complex tasks. *)
let decode_task ~task_id ~(instructions : instruction list) : micro_op list =
  let now = Unix.gettimeofday () in
  let ops = List.mapi (fun i instr ->
    let id = generate_op_id ~task_id in
    let deps = if i = 0 then []
      else [generate_op_id ~task_id]  (* sequential dependency *)
    in
    {
      id;
      parent_task_id = task_id;
      instruction = instr;
      stage = Stage_fetch;
      issued_at = now;
      dependencies = deps;
      result = None;
    }
  ) instructions in
  (* Fix: re-generate IDs consistently so deps point to actual ops *)
  let ids = List.mapi (fun _ op -> op.id) ops in
  List.mapi (fun i op ->
    let deps = if i = 0 then []
      else [List.nth ids (i - 1)]
    in
    { op with dependencies = deps }
  ) ops

(* ================================================================ *)
(* Hazard Detection                                                 *)
(* ================================================================ *)

(** Check for Read-After-Write hazard between two micro-ops.

    A RAW hazard exists when a downstream op reads a register
    that an upstream op writes but hasn't completed yet. *)
let detect_raw_hazard ~(producer : micro_op) ~(consumer : micro_op) : hazard option =
  (* In Phase 1, we use a simplified model:
     - EXEC/STORE produce to R2_RESULT
     - LOAD/FETCH produce to R2_RESULT
     - Any op that depends on producer has a potential RAW *)
  let produces_result = match producer.instruction with
    | EXEC _ | STORE _ | LOAD _ | FETCH _ | SPEC _ -> true
    | DECODE _ | BRANCH _ | COMMIT _ | ABORT _ | SYNC _ | YIELD _ | HALT _ -> false
  in
  let consumes_result = match consumer.instruction with
    | EXEC _ | STORE _ | BRANCH _ | COMMIT _ -> true
    | FETCH _ | DECODE _ | LOAD _ | SPEC _ | ABORT _ | SYNC _ | YIELD _ | HALT _ -> false
  in
  if produces_result && consumes_result
     && List.mem producer.id consumer.dependencies then
    Some (RAW {
      producer = producer.id;
      consumer = consumer.id;
      register = R2_RESULT;
    })
  else
    None

(** Check for control hazard at a BRANCH instruction. *)
let detect_control_hazard (op : micro_op) : hazard option =
  match op.instruction with
  | BRANCH _ -> Some (Control { branch_op = op.id })
  | _ -> None

(** Check for structural hazard: multiple ops need the same tool/resource. *)
let detect_structural_hazard (ops : micro_op list) : hazard option =
  let tool_users = List.filter_map (fun op ->
    match op.instruction with
    | EXEC { tool; _ } -> Some (tool, op.id)
    | _ -> None
  ) ops in
  (* Group by tool *)
  let tools = List.sort_uniq compare
    (List.map fst tool_users) in
  let conflicts = List.filter_map (fun tool ->
    let users = List.filter_map (fun (t, id) ->
      if t = tool then Some id else None
    ) tool_users in
    if List.length users > 1 then
      Some (Structural { resource = tool; contenders = users })
    else None
  ) tools in
  match conflicts with
  | h :: _ -> Some h
  | [] -> None

(* ================================================================ *)
(* Pipeline Advance (single cycle)                                  *)
(* ================================================================ *)

(** Result of advancing the pipeline one cycle. *)
type advance_result = {
  pipeline : agent_pipeline;
  completed : micro_op list;     (** Ops that exited writeback *)
  hazards : hazard list;          (** Hazards detected this cycle *)
  stalled : bool;                 (** Whether pipeline stalled *)
}

(** Check if all dependencies of a micro-op are resolved.
    A dependency is resolved when its result is available (not None). *)
let dependencies_resolved ~(completed_ids : string list) (op : micro_op) : bool =
  List.for_all (fun dep_id ->
    List.mem dep_id completed_ids
  ) op.dependencies

(** Advance the pipeline by one cycle.

    In-order pipeline rules:
    1. Writeback -> completed (results written to register file)
    2. Execute -> Writeback (if writeback is free)
    3. Schedule -> Execute (if execute is free AND no hazards)
    4. Decode -> Schedule (if schedule is free)
    5. Fetch -> Decode (if decode is free)
    6. New op -> Fetch (if fetch is free)

    Stalls propagate backward: if execute stalls, schedule/decode/fetch
    all stall too (pipeline bubble). *)
let advance
    ~(completed_ids : string list)
    ~(pending_ops : micro_op list)
    (pipeline : agent_pipeline)
  : advance_result =
  let metrics = pipeline.metrics in
  let hazards = ref [] in
  let completed = ref [] in

  (* Phase 1: Writeback -> complete *)
  let new_writeback, wb_completed = match pipeline.writeback_slot with
    | Some op ->
        metrics.completed_ops <- metrics.completed_ops + 1;
        (None, [op])
    | None -> (None, [])
  in
  completed := wb_completed;

  (* Phase 2: Execute -> Writeback *)
  let new_execute, can_advance_exec = match pipeline.execute_slot with
    | Some op when Option.is_none new_writeback ->
        (* Simulate execution: mark as having a result *)
        let finished_op = { op with
          stage = Stage_writeback;
          result = Some (`String "executed");
        } in
        (None, Some finished_op)
    | Some _ -> (pipeline.execute_slot, None)  (* Writeback full, stall *)
    | None -> (None, None)
  in
  let new_writeback = match can_advance_exec with
    | Some op -> Some op
    | None -> new_writeback
  in

  (* Phase 3: Schedule -> Execute *)
  let stall_detected = ref false in
  let new_schedule, can_advance_sched = match pipeline.schedule_slot with
    | Some op when Option.is_none new_execute ->
        (* Check hazards before issuing *)
        let raw_hazards = match pipeline.execute_slot with
          | Some exec_op ->
              (match detect_raw_hazard ~producer:exec_op ~consumer:op with
               | Some h -> [h]
               | None -> [])
          | None -> []
        in
        let ctrl_hazards = match detect_control_hazard op with
          | Some h -> [h]
          | None -> []
        in
        let all_hazards = raw_hazards @ ctrl_hazards in
        if all_hazards <> [] then begin
          hazards := all_hazards @ !hazards;
          metrics.hazards_detected <- metrics.hazards_detected + List.length all_hazards;
          metrics.stalled_cycles <- metrics.stalled_cycles + 1;
          stall_detected := true;
          (pipeline.schedule_slot, None)  (* Stall *)
        end else if dependencies_resolved ~completed_ids op then begin
          let issued_op = { op with stage = Stage_execute } in
          (None, Some issued_op)
        end else begin
          metrics.stalled_cycles <- metrics.stalled_cycles + 1;
          stall_detected := true;
          (pipeline.schedule_slot, None)
        end
    | Some _ -> (pipeline.schedule_slot, None)  (* Execute full, stall *)
    | None -> (None, None)
  in
  let new_execute = match can_advance_sched with
    | Some op -> Some op
    | None -> new_execute
  in

  (* Phase 4: Decode -> Schedule *)
  let new_decode, can_advance_dec = match pipeline.decode_slot with
    | Some op when Option.is_none new_schedule && not !stall_detected ->
        let decoded_op = { op with stage = Stage_schedule } in
        (None, Some decoded_op)
    | Some _ -> (pipeline.decode_slot, None)
    | None -> (None, None)
  in
  let new_schedule = match can_advance_dec with
    | Some op -> Some op
    | None -> new_schedule
  in

  (* Phase 5: Fetch -> Decode *)
  let new_fetch, can_advance_fetch = match pipeline.fetch_slot with
    | Some op when Option.is_none new_decode && not !stall_detected ->
        let fetched_op = { op with stage = Stage_decode } in
        (None, Some fetched_op)
    | Some _ -> (pipeline.fetch_slot, None)
    | None -> (None, None)
  in
  let new_decode = match can_advance_fetch with
    | Some op -> Some op
    | None -> new_decode
  in

  (* Phase 6: Insert new op into Fetch *)
  let new_fetch = match new_fetch with
    | None when not !stall_detected ->
        (match pending_ops with
         | op :: _ ->
             metrics.total_ops <- metrics.total_ops + 1;
             Some { op with stage = Stage_fetch }
         | [] -> None)
    | _ -> new_fetch
  in

  (* Check structural hazards across all active ops *)
  let active_ops = List.filter_map Fun.id [
    new_fetch; new_decode; new_schedule; new_execute; new_writeback
  ] in
  (match detect_structural_hazard active_ops with
   | Some h ->
       hazards := h :: !hazards;
       metrics.hazards_detected <- metrics.hazards_detected + 1
   | None -> ());

  let new_pipeline = {
    pipeline with
    fetch_slot = new_fetch;
    decode_slot = new_decode;
    schedule_slot = new_schedule;
    execute_slot = new_execute;
    writeback_slot = new_writeback;
    stall = !stall_detected;
    stall_reason = (match !hazards with h :: _ -> Some h | [] -> None);
  } in
  {
    pipeline = new_pipeline;
    completed = !completed;
    hazards = !hazards;
    stalled = !stall_detected;
  }

(* ================================================================ *)
(* Pipeline Registry (multi-agent)                                  *)
(* ================================================================ *)

(** Global registry of agent pipelines.

    Thread-safe via Eio.Mutex (not OS mutex).
    Each agent_id maps to its pipeline state. *)
type pipeline_registry = {
  pipelines : (string, agent_pipeline) Hashtbl.t;
  mutable global_cycle : int;
}

let create_registry () = {
  pipelines = Hashtbl.create 16;
  global_cycle = 0;
}

let register_agent registry agent_id =
  if not (Hashtbl.mem registry.pipelines agent_id) then
    Hashtbl.replace registry.pipelines agent_id (create_agent_pipeline agent_id)

let unregister_agent registry agent_id =
  Hashtbl.remove registry.pipelines agent_id

let get_pipeline registry agent_id =
  Hashtbl.find_opt registry.pipelines agent_id

let update_pipeline registry agent_id pipeline =
  Hashtbl.replace registry.pipelines agent_id pipeline

(** Advance all agent pipelines by one global cycle. *)
let tick ~completed_ids ~(pending : (string * micro_op list) list) registry =
  registry.global_cycle <- registry.global_cycle + 1;
  let all_completed = ref [] in
  let all_hazards = ref [] in
  Hashtbl.iter (fun agent_id pipeline ->
    let agent_pending = match List.assoc_opt agent_id pending with
      | Some ops -> ops
      | None -> []
    in
    let result = advance ~completed_ids ~pending_ops:agent_pending pipeline in
    update_pipeline registry agent_id result.pipeline;
    all_completed := result.completed @ !all_completed;
    all_hazards := result.hazards @ !all_hazards;
  ) registry.pipelines;
  (!all_completed, !all_hazards)

(** Get summary of all pipelines for observability. *)
let registry_status registry =
  let pipelines = Hashtbl.fold (fun _id p acc ->
    agent_pipeline_to_yojson p :: acc
  ) registry.pipelines [] in
  `Assoc [
    ("global_cycle", `Int registry.global_cycle);
    ("agent_count", `Int (Hashtbl.length registry.pipelines));
    ("pipelines", `List pipelines);
  ]

(** Compute aggregate metrics across all pipelines. *)
let aggregate_metrics registry =
  let total = create_metrics () in
  Hashtbl.iter (fun _id p ->
    let m = p.metrics in
    total.total_ops <- total.total_ops + m.total_ops;
    total.completed_ops <- total.completed_ops + m.completed_ops;
    total.stalled_cycles <- total.stalled_cycles + m.stalled_cycles;
    total.hazards_detected <- total.hazards_detected + m.hazards_detected;
    total.forwarding_used <- total.forwarding_used + m.forwarding_used;
    total.pipeline_flushes <- total.pipeline_flushes + m.pipeline_flushes;
  ) registry.pipelines;
  total

(** Flush a specific agent's pipeline (discard all in-flight ops). *)
let flush_pipeline registry agent_id =
  match get_pipeline registry agent_id with
  | Some p ->
      p.metrics.pipeline_flushes <- p.metrics.pipeline_flushes + 1;
      let flushed = create_agent_pipeline agent_id in
      (* Preserve metrics across flush *)
      let preserved = { flushed with metrics = p.metrics } in
      update_pipeline registry agent_id preserved;
      true
  | None -> false
