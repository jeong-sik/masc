(** SWARM-RISC Types -- Agent ISA for MASC-MCP

    Defines the Instruction Set Architecture (ISA) for multi-agent
    coordination.  12 RISC instructions, 16 virtual registers,
    pipeline stages, and supporting types.

    Design principle: ISA is the stable interface visible to agents.
    Microarchitecture (pipeline, cache, OoO) is transparent.

    @since 2.78.0 *)

(* ================================================================ *)
(* ISA: Instructions (12 RISC opcodes)                              *)
(* ================================================================ *)

(** Priority level for task fetching. *)
type priority = Urgent | High | Normal | Low | Background

let priority_to_int = function
  | Urgent -> 1 | High -> 2 | Normal -> 3 | Low -> 4 | Background -> 5

let priority_of_int = function
  | 1 -> Urgent | 2 -> High | 3 -> Normal | 4 -> Low | 5 -> Background
  | n -> if n <= 1 then Urgent else Background

let priority_to_string = function
  | Urgent -> "urgent" | High -> "high" | Normal -> "normal"
  | Low -> "low" | Background -> "background"

let priority_to_yojson p = `String (priority_to_string p)

let priority_of_yojson = function
  | `String "urgent" -> Ok Urgent
  | `String "high" -> Ok High
  | `String "normal" -> Ok Normal
  | `String "low" -> Ok Low
  | `String "background" -> Ok Background
  | `Int n -> Ok (priority_of_int n)
  | _ -> Error "priority: expected string or int"

(** Cache scope for LOAD/STORE operations. *)
type cache_scope =
  | L1_agent   (** Per-agent in-memory cache *)
  | L2_room    (** Room-level file-backed cache *)
  | L3_global  (** PostgreSQL-backed global store *)

let cache_scope_to_string = function
  | L1_agent -> "L1" | L2_room -> "L2" | L3_global -> "L3"

let cache_scope_of_string = function
  | "L1" | "l1" -> Ok L1_agent
  | "L2" | "l2" -> Ok L2_room
  | "L3" | "l3" -> Ok L3_global
  | s -> Error ("Unknown cache scope: " ^ s)

let cache_scope_to_yojson s = `String (cache_scope_to_string s)

let cache_scope_of_yojson = function
  | `String s -> cache_scope_of_string s
  | _ -> Error "cache_scope: expected string"

(** Speculative execution model selector. *)
type spec_model =
  | Fast_local    (** Local fast LLM (glm-flash, LFM2.5) *)
  | Fast_cloud    (** Cloud fast LLM (haiku, flash) *)

let spec_model_to_string = function
  | Fast_local -> "fast_local" | Fast_cloud -> "fast_cloud"

let spec_model_to_yojson m = `String (spec_model_to_string m)

let spec_model_of_yojson = function
  | `String "fast_local" -> Ok Fast_local
  | `String "fast_cloud" -> Ok Fast_cloud
  | _ -> Error "spec_model: expected fast_local or fast_cloud"

(** The 12 RISC instructions for the Agent ISA.

    Each instruction maps to a specific coordination primitive.
    The ISA is intentionally small (RISC philosophy) -- compound
    operations are expressed as sequences of these primitives. *)
type instruction =
  | FETCH of { task_spec : string; priority : priority }
      (** Pull next task matching spec from backlog. *)
  | DECODE of { task_id : string }
      (** Parse task into dependency graph of micro-ops. *)
  | EXEC of { op_id : string; tool : string; args : Yojson.Safe.t }
      (** Execute a single tool operation. *)
  | STORE of { key : string; value : Yojson.Safe.t; scope : cache_scope }
      (** Write to cache hierarchy with coherence. *)
  | LOAD of { key : string; scope : cache_scope }
      (** Read from cache with coherence probe. *)
  | BRANCH of {
      condition : string;
      target_a : string;
      target_b : string;
    }
      (** Conditional path selection (MCTS branch point). *)
  | SPEC of { model : spec_model; op_id : string }
      (** Speculative execution with fast LLM. *)
  | COMMIT of { spec_id : string }
      (** Commit speculative result after verification. *)
  | ABORT of { spec_id : string }
      (** Discard speculative result, rollback. *)
  | SYNC of { barrier_id : string; agents : string list }
      (** Memory fence: ensure consistent state across agents. *)
  | YIELD of { reason : string }
      (** Voluntary preemption, release execution slot. *)
  | HALT of { exit_code : int; dna : Yojson.Safe.t option }
      (** Terminate with optional succession DNA transfer. *)

(** Opcode numeric encoding (0x01-0x0C). *)
let opcode_of_instruction = function
  | FETCH _ -> 0x01 | DECODE _ -> 0x02 | EXEC _ -> 0x03
  | STORE _ -> 0x04 | LOAD _ -> 0x05  | BRANCH _ -> 0x06
  | SPEC _ -> 0x07  | COMMIT _ -> 0x08 | ABORT _ -> 0x09
  | SYNC _ -> 0x0A  | YIELD _ -> 0x0B | HALT _ -> 0x0C

let mnemonic_of_instruction = function
  | FETCH _ -> "FETCH" | DECODE _ -> "DECODE" | EXEC _ -> "EXEC"
  | STORE _ -> "STORE" | LOAD _ -> "LOAD"   | BRANCH _ -> "BRANCH"
  | SPEC _ -> "SPEC"   | COMMIT _ -> "COMMIT" | ABORT _ -> "ABORT"
  | SYNC _ -> "SYNC"   | YIELD _ -> "YIELD"  | HALT _ -> "HALT"

let instruction_to_yojson instr =
  let base = [
    ("opcode", `Int (opcode_of_instruction instr));
    ("mnemonic", `String (mnemonic_of_instruction instr));
  ] in
  let operands = match instr with
    | FETCH { task_spec; priority } ->
        [("task_spec", `String task_spec);
         ("priority", priority_to_yojson priority)]
    | DECODE { task_id } ->
        [("task_id", `String task_id)]
    | EXEC { op_id; tool; args } ->
        [("op_id", `String op_id);
         ("tool", `String tool);
         ("args", args)]
    | STORE { key; value; scope } ->
        [("key", `String key);
         ("value", value);
         ("scope", cache_scope_to_yojson scope)]
    | LOAD { key; scope } ->
        [("key", `String key);
         ("scope", cache_scope_to_yojson scope)]
    | BRANCH { condition; target_a; target_b } ->
        [("condition", `String condition);
         ("target_a", `String target_a);
         ("target_b", `String target_b)]
    | SPEC { model; op_id } ->
        [("model", spec_model_to_yojson model);
         ("op_id", `String op_id)]
    | COMMIT { spec_id } -> [("spec_id", `String spec_id)]
    | ABORT { spec_id } -> [("spec_id", `String spec_id)]
    | SYNC { barrier_id; agents } ->
        [("barrier_id", `String barrier_id);
         ("agents", `List (List.map (fun a -> `String a) agents))]
    | YIELD { reason } -> [("reason", `String reason)]
    | HALT { exit_code; dna } ->
        [("exit_code", `Int exit_code);
         ("dna", match dna with Some d -> d | None -> `Null)]
  in
  `Assoc (base @ operands)

(* ================================================================ *)
(* Register File (16 virtual registers per agent)                   *)
(* ================================================================ *)

(** Register names in the virtual register file. *)
type register =
  | R0_ZERO     (** Always zero *)
  | R1_TASK     (** Current task_id *)
  | R2_RESULT   (** Last operation result *)
  | R3_STATUS   (** Agent status flags *)
  | R4_GP0 | R5_GP1 | R6_GP2 | R7_GP3  (** General purpose *)
  | R8_SPEC0 | R9_SPEC1 | R10_SPEC2 | R11_SPEC3  (** Speculative buffers *)
  | R12_CTX_PTR (** Context window pointer (token count) *)
  | R13_GEN     (** Generation counter *)
  | R14_COST    (** Accumulated cost (USD * 10000) *)
  | R15_PC      (** Program counter *)

let register_index = function
  | R0_ZERO -> 0  | R1_TASK -> 1  | R2_RESULT -> 2  | R3_STATUS -> 3
  | R4_GP0 -> 4   | R5_GP1 -> 5   | R6_GP2 -> 6     | R7_GP3 -> 7
  | R8_SPEC0 -> 8 | R9_SPEC1 -> 9 | R10_SPEC2 -> 10 | R11_SPEC3 -> 11
  | R12_CTX_PTR -> 12 | R13_GEN -> 13 | R14_COST -> 14 | R15_PC -> 15

let register_name = function
  | R0_ZERO -> "ZERO" | R1_TASK -> "TASK" | R2_RESULT -> "RESULT"
  | R3_STATUS -> "STATUS"
  | R4_GP0 -> "GP0" | R5_GP1 -> "GP1" | R6_GP2 -> "GP2" | R7_GP3 -> "GP3"
  | R8_SPEC0 -> "SPEC0" | R9_SPEC1 -> "SPEC1"
  | R10_SPEC2 -> "SPEC2" | R11_SPEC3 -> "SPEC3"
  | R12_CTX_PTR -> "CTX_PTR" | R13_GEN -> "GEN"
  | R14_COST -> "COST" | R15_PC -> "PC"

let all_registers = [
  R0_ZERO; R1_TASK; R2_RESULT; R3_STATUS;
  R4_GP0; R5_GP1; R6_GP2; R7_GP3;
  R8_SPEC0; R9_SPEC1; R10_SPEC2; R11_SPEC3;
  R12_CTX_PTR; R13_GEN; R14_COST; R15_PC;
]

(** Register file: maps register index to JSON value. *)
type register_file = {
  values : Yojson.Safe.t array;  (** 16 slots *)
}

let create_register_file () =
  { values = Array.make 16 `Null }

let read_register rf reg =
  rf.values.(register_index reg)

let write_register rf reg value =
  if reg = R0_ZERO then ()  (* R0 is hardwired to zero/null *)
  else rf.values.(register_index reg) <- value

let register_file_to_yojson rf =
  let entries = List.map (fun r ->
    (register_name r, rf.values.(register_index r))
  ) all_registers in
  `Assoc entries

(* ================================================================ *)
(* Pipeline Stages                                                  *)
(* ================================================================ *)

(** The 5 pipeline stages: Fetch, Decode, Schedule, Execute, Writeback. *)
type pipeline_stage =
  | Stage_fetch
  | Stage_decode
  | Stage_schedule
  | Stage_execute
  | Stage_writeback

let stage_to_string = function
  | Stage_fetch -> "fetch"
  | Stage_decode -> "decode"
  | Stage_schedule -> "schedule"
  | Stage_execute -> "execute"
  | Stage_writeback -> "writeback"

let all_stages = [
  Stage_fetch; Stage_decode; Stage_schedule;
  Stage_execute; Stage_writeback;
]

(** A micro-operation: the smallest unit of work in the pipeline. *)
type micro_op = {
  id : string;
  parent_task_id : string;
  instruction : instruction;
  stage : pipeline_stage;
  issued_at : float;
  dependencies : string list;  (** IDs of micro-ops this depends on *)
  result : Yojson.Safe.t option;
}

let micro_op_to_yojson op =
  `Assoc [
    ("id", `String op.id);
    ("parent_task_id", `String op.parent_task_id);
    ("instruction", instruction_to_yojson op.instruction);
    ("stage", `String (stage_to_string op.stage));
    ("issued_at", `Float op.issued_at);
    ("dependencies", `List (List.map (fun d -> `String d) op.dependencies));
    ("result", match op.result with Some r -> r | None -> `Null);
  ]

(* ================================================================ *)
(* Pipeline Hazards                                                 *)
(* ================================================================ *)

(** Pipeline hazard types that can cause stalls. *)
type hazard =
  | RAW of { producer : string; consumer : string; register : register }
      (** Read-After-Write: consumer needs producer output. *)
  | Control of { branch_op : string }
      (** Control hazard: branch outcome unknown. *)
  | Structural of { resource : string; contenders : string list }
      (** Structural: multiple ops need same resource. *)

let hazard_to_string = function
  | RAW { producer; consumer; register } ->
      Printf.sprintf "RAW(%s->%s via %s)" producer consumer (register_name register)
  | Control { branch_op } ->
      Printf.sprintf "Control(%s)" branch_op
  | Structural { resource; contenders } ->
      Printf.sprintf "Structural(%s: %s)" resource (String.concat "," contenders)

let hazard_to_yojson = function
  | RAW { producer; consumer; register } ->
      `Assoc [("type", `String "RAW");
              ("producer", `String producer);
              ("consumer", `String consumer);
              ("register", `String (register_name register))]
  | Control { branch_op } ->
      `Assoc [("type", `String "Control");
              ("branch_op", `String branch_op)]
  | Structural { resource; contenders } ->
      `Assoc [("type", `String "Structural");
              ("resource", `String resource);
              ("contenders", `List (List.map (fun c -> `String c) contenders))]

(* ================================================================ *)
(* Pipeline Metrics                                                 *)
(* ================================================================ *)

(** Accumulated pipeline metrics for observability. *)
type pipeline_metrics = {
  mutable total_ops : int;
  mutable completed_ops : int;
  mutable stalled_cycles : int;
  mutable hazards_detected : int;
  mutable forwarding_used : int;
  mutable pipeline_flushes : int;
}

let create_metrics () = {
  total_ops = 0;
  completed_ops = 0;
  stalled_cycles = 0;
  hazards_detected = 0;
  forwarding_used = 0;
  pipeline_flushes = 0;
}

let ipc metrics =
  if metrics.total_ops = 0 then 0.0
  else float_of_int metrics.completed_ops /. float_of_int metrics.total_ops

let metrics_to_yojson m =
  `Assoc [
    ("total_ops", `Int m.total_ops);
    ("completed_ops", `Int m.completed_ops);
    ("stalled_cycles", `Int m.stalled_cycles);
    ("hazards_detected", `Int m.hazards_detected);
    ("forwarding_used", `Int m.forwarding_used);
    ("pipeline_flushes", `Int m.pipeline_flushes);
    ("ipc", `Float (ipc m));
  ]

(* ================================================================ *)
(* Agent Pipeline State                                             *)
(* ================================================================ *)

(** Per-agent pipeline state: tracks what each agent is processing. *)
type agent_pipeline = {
  agent_id : string;
  register_file : register_file;
  fetch_slot : micro_op option;
  decode_slot : micro_op option;
  schedule_slot : micro_op option;
  execute_slot : micro_op option;
  writeback_slot : micro_op option;
  stall : bool;
  stall_reason : hazard option;
  metrics : pipeline_metrics;
}

let create_agent_pipeline agent_id = {
  agent_id;
  register_file = create_register_file ();
  fetch_slot = None;
  decode_slot = None;
  schedule_slot = None;
  execute_slot = None;
  writeback_slot = None;
  stall = false;
  stall_reason = None;
  metrics = create_metrics ();
}

let stage_occupancy pipeline =
  let occupied s = if Option.is_some s then 1 else 0 in
  let total =
    occupied pipeline.fetch_slot
    + occupied pipeline.decode_slot
    + occupied pipeline.schedule_slot
    + occupied pipeline.execute_slot
    + occupied pipeline.writeback_slot
  in
  (total, 5)

let agent_pipeline_to_yojson p =
  let slot_json name = function
    | None -> (name, `Null)
    | Some op -> (name, micro_op_to_yojson op)
  in
  let occ_n, occ_d = stage_occupancy p in
  `Assoc [
    ("agent_id", `String p.agent_id);
    ("registers", register_file_to_yojson p.register_file);
    (slot_json "fetch" p.fetch_slot);
    (slot_json "decode" p.decode_slot);
    (slot_json "schedule" p.schedule_slot);
    (slot_json "execute" p.execute_slot);
    (slot_json "writeback" p.writeback_slot);
    ("stall", `Bool p.stall);
    ("stall_reason", match p.stall_reason with
      | None -> `Null
      | Some h -> hazard_to_yojson h);
    ("occupancy", `String (Printf.sprintf "%d/%d" occ_n occ_d));
    ("metrics", metrics_to_yojson p.metrics);
  ]
