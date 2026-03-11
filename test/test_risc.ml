(** Test SWARM-RISC -- ISA Types, Pipeline, and Tool Dispatch

    Covers:
    - Instruction encoding/decoding roundtrip
    - Register file operations (R0 hardwire, read/write)
    - Pipeline stage transitions and hazard detection
    - Pipeline advance cycle (in-order)
    - Pipeline registry (multi-agent)
    - Tool dispatch (parse_instruction, decode, status, metrics)

    @since 2.78.0 *)

open Masc_mcp

let pass name = Printf.printf "  PASS %s\n%!" name
let fail name msg = Printf.printf "  FAIL %s: %s\n%!" name msg; exit 1

let dummy_model : Llm_client.model_spec = {
  provider = Llm_client.Llama;
  model_id = "test-fast-model";
  max_context = 4096;
  api_url = "http://localhost:8085";
  api_key_env = None;
  cost_per_1k_input = 0.0;
  cost_per_1k_output = 0.0;
}

(* ================================================================ *)
(* risc_types.ml tests                                              *)
(* ================================================================ *)

let test_priority_roundtrip () =
  let name = "priority_roundtrip" in
  let priorities = [Risc_types.Urgent; High; Normal; Low; Background] in
  List.iter (fun p ->
    let i = Risc_types.priority_to_int p in
    let p2 = Risc_types.priority_of_int i in
    if Risc_types.priority_to_string p <> Risc_types.priority_to_string p2 then
      fail name (Printf.sprintf "roundtrip failed for %s" (Risc_types.priority_to_string p))
  ) priorities;
  pass name

let test_cache_scope_roundtrip () =
  let name = "cache_scope_roundtrip" in
  let scopes = [Risc_types.L1_agent; L2_room; L3_global] in
  List.iter (fun s ->
    let str = Risc_types.cache_scope_to_string s in
    match Risc_types.cache_scope_of_string str with
    | Ok s2 when Risc_types.cache_scope_to_string s2 = str -> ()
    | _ -> fail name (Printf.sprintf "roundtrip failed for %s" str)
  ) scopes;
  pass name

let test_opcode_unique () =
  let name = "opcode_unique" in
  let instrs = [
    Risc_types.FETCH { task_spec = ""; priority = Normal };
    DECODE { task_id = "" };
    EXEC { op_id = ""; tool = ""; args = `Null };
    STORE { key = ""; value = `Null; scope = L1_agent };
    LOAD { key = ""; scope = L1_agent };
    BRANCH { condition = ""; target_a = ""; target_b = "" };
    SPEC { model = Fast_local; op_id = "" };
    COMMIT { spec_id = "" };
    ABORT { spec_id = "" };
    SYNC { barrier_id = ""; agents = [] };
    YIELD { reason = "" };
    HALT { exit_code = 0; dna = None };
  ] in
  let opcodes = List.map Risc_types.opcode_of_instruction instrs in
  let unique = List.sort_uniq compare opcodes in
  if List.length unique <> 12 then
    fail name (Printf.sprintf "expected 12 unique opcodes, got %d" (List.length unique))
  else
    pass name

let test_mnemonic_consistency () =
  let name = "mnemonic_consistency" in
  let instr = Risc_types.FETCH { task_spec = "test"; priority = High } in
  let json = Risc_types.instruction_to_yojson instr in
  let mnemonic = Yojson.Safe.Util.(json |> member "mnemonic" |> to_string) in
  if mnemonic <> "FETCH" then
    fail name (Printf.sprintf "expected FETCH, got %s" mnemonic)
  else
    pass name

let test_instruction_to_yojson_roundtrip () =
  let name = "instruction_to_yojson" in
  let instr = Risc_types.EXEC {
    op_id = "op-001";
    tool = "masc_broadcast";
    args = `Assoc [("message", `String "hello")];
  } in
  let json = Risc_types.instruction_to_yojson instr in
  let opcode = Yojson.Safe.Util.(json |> member "opcode" |> to_int) in
  let tool = Yojson.Safe.Util.(json |> member "tool" |> to_string) in
  if opcode <> 0x03 then
    fail name (Printf.sprintf "expected opcode 3, got %d" opcode)
  else if tool <> "masc_broadcast" then
    fail name (Printf.sprintf "expected tool masc_broadcast, got %s" tool)
  else
    pass name

(* ================================================================ *)
(* Register file tests                                              *)
(* ================================================================ *)

let test_register_r0_hardwire () =
  let name = "register_r0_hardwire" in
  let rf = Risc_types.create_register_file () in
  Risc_types.write_register rf R0_ZERO (`Int 42);
  let v = Risc_types.read_register rf R0_ZERO in
  if v <> `Null then
    fail name "R0 should always be Null"
  else
    pass name

let test_register_read_write () =
  let name = "register_read_write" in
  let rf = Risc_types.create_register_file () in
  Risc_types.write_register rf R1_TASK (`String "task-123");
  Risc_types.write_register rf R14_COST (`Int 5000);
  let task = Risc_types.read_register rf R1_TASK in
  let cost = Risc_types.read_register rf R14_COST in
  if task <> `String "task-123" then
    fail name "R1_TASK mismatch"
  else if cost <> `Int 5000 then
    fail name "R14_COST mismatch"
  else
    pass name

let test_register_file_to_yojson () =
  let name = "register_file_to_yojson" in
  let rf = Risc_types.create_register_file () in
  Risc_types.write_register rf R2_RESULT (`String "ok");
  let json = Risc_types.register_file_to_yojson rf in
  let result_val = Yojson.Safe.Util.(json |> member "RESULT" |> to_string) in
  if result_val <> "ok" then
    fail name (Printf.sprintf "expected 'ok', got '%s'" result_val)
  else
    pass name

let test_all_registers_indexed () =
  let name = "all_registers_indexed" in
  let indices = List.map Risc_types.register_index Risc_types.all_registers in
  let unique = List.sort_uniq compare indices in
  if List.length unique <> 16 then
    fail name "expected 16 unique register indices"
  else
    pass name

(* ================================================================ *)
(* Pipeline stage tests                                             *)
(* ================================================================ *)

let test_stage_names () =
  let name = "stage_names" in
  let names = List.map Risc_types.stage_to_string Risc_types.all_stages in
  if List.length names <> 5 then
    fail name "expected 5 stages"
  else if List.hd names <> "fetch" then
    fail name "first stage should be 'fetch'"
  else
    pass name

let test_micro_op_to_yojson () =
  let name = "micro_op_to_yojson" in
  let op : Risc_types.micro_op = {
    id = "uop-test-0001";
    parent_task_id = "task-001";
    instruction = EXEC { op_id = "op-1"; tool = "test"; args = `Null };
    stage = Stage_execute;
    issued_at = 1000.0;
    dependencies = ["uop-test-0000"];
    result = Some (`String "done");
  } in
  let json = Risc_types.micro_op_to_yojson op in
  let id = Yojson.Safe.Util.(json |> member "id" |> to_string) in
  let stage = Yojson.Safe.Util.(json |> member "stage" |> to_string) in
  if id <> "uop-test-0001" then fail name "id mismatch"
  else if stage <> "execute" then fail name "stage mismatch"
  else pass name

(* ================================================================ *)
(* Hazard detection tests                                           *)
(* ================================================================ *)

let test_raw_hazard_detection () =
  let name = "raw_hazard_detection" in
  let producer : Risc_types.micro_op = {
    id = "uop-p"; parent_task_id = "t1";
    instruction = EXEC { op_id = "op-p"; tool = "t"; args = `Null };
    stage = Stage_execute; issued_at = 0.0;
    dependencies = []; result = None;
  } in
  let consumer : Risc_types.micro_op = {
    id = "uop-c"; parent_task_id = "t1";
    instruction = EXEC { op_id = "op-c"; tool = "t2"; args = `Null };
    stage = Stage_schedule; issued_at = 0.0;
    dependencies = ["uop-p"]; result = None;
  } in
  match Risc_pipeline.detect_raw_hazard ~producer ~consumer with
  | Some (RAW _) -> pass name
  | Some _ -> fail name "expected RAW hazard"
  | None -> fail name "should detect RAW hazard"

let test_no_hazard_independent () =
  let name = "no_hazard_independent" in
  let op1 : Risc_types.micro_op = {
    id = "uop-1"; parent_task_id = "t1";
    instruction = EXEC { op_id = "op-1"; tool = "t"; args = `Null };
    stage = Stage_execute; issued_at = 0.0;
    dependencies = []; result = None;
  } in
  let op2 : Risc_types.micro_op = {
    id = "uop-2"; parent_task_id = "t1";
    instruction = EXEC { op_id = "op-2"; tool = "t"; args = `Null };
    stage = Stage_schedule; issued_at = 0.0;
    dependencies = [];  (* No dependency on op1 *)
    result = None;
  } in
  match Risc_pipeline.detect_raw_hazard ~producer:op1 ~consumer:op2 with
  | None -> pass name
  | Some _ -> fail name "should not detect hazard for independent ops"

let test_control_hazard () =
  let name = "control_hazard" in
  let op : Risc_types.micro_op = {
    id = "uop-br"; parent_task_id = "t1";
    instruction = BRANCH { condition = "x>0"; target_a = "a"; target_b = "b" };
    stage = Stage_schedule; issued_at = 0.0;
    dependencies = []; result = None;
  } in
  match Risc_pipeline.detect_control_hazard op with
  | Some (Control _) -> pass name
  | _ -> fail name "should detect control hazard for BRANCH"

let test_structural_hazard () =
  let name = "structural_hazard" in
  let ops : Risc_types.micro_op list = [
    { id = "uop-1"; parent_task_id = "t1";
      instruction = EXEC { op_id = "op-1"; tool = "llm_call"; args = `Null };
      stage = Stage_execute; issued_at = 0.0;
      dependencies = []; result = None };
    { id = "uop-2"; parent_task_id = "t1";
      instruction = EXEC { op_id = "op-2"; tool = "llm_call"; args = `Null };
      stage = Stage_schedule; issued_at = 0.0;
      dependencies = []; result = None };
  ] in
  match Risc_pipeline.detect_structural_hazard ops with
  | Some (Structural { resource; _ }) when resource = "llm_call" -> pass name
  | Some (Structural _) -> fail name "wrong resource"
  | _ -> fail name "should detect structural hazard"

(* ================================================================ *)
(* Pipeline advance tests                                           *)
(* ================================================================ *)

let test_pipeline_empty_advance () =
  let name = "pipeline_empty_advance" in
  let p = Risc_types.create_agent_pipeline "agent-1" in
  let result = Risc_pipeline.advance ~completed_ids:[] ~pending_ops:[] p in
  if result.stalled then fail name "empty pipeline should not stall"
  else if result.completed <> [] then fail name "no ops should complete"
  else pass name

let test_pipeline_single_op_flow () =
  let name = "pipeline_single_op_flow" in
  let p = Risc_types.create_agent_pipeline "agent-1" in
  let op : Risc_types.micro_op = {
    id = "uop-001"; parent_task_id = "task-1";
    instruction = EXEC { op_id = "op-1"; tool = "test"; args = `Null };
    stage = Stage_fetch; issued_at = 0.0;
    dependencies = []; result = None;
  } in
  (* Cycle 1: op enters Fetch *)
  let r1 = Risc_pipeline.advance ~completed_ids:[] ~pending_ops:[op] p in
  if Option.is_none r1.pipeline.fetch_slot then
    fail name "op should be in fetch after cycle 1"
  else
  (* Cycle 2: Fetch -> Decode *)
  let r2 = Risc_pipeline.advance ~completed_ids:[] ~pending_ops:[] r1.pipeline in
  if Option.is_none r2.pipeline.decode_slot then
    fail name "op should be in decode after cycle 2"
  else
  (* Cycle 3: Decode -> Schedule *)
  let r3 = Risc_pipeline.advance ~completed_ids:[] ~pending_ops:[] r2.pipeline in
  if Option.is_none r3.pipeline.schedule_slot then
    fail name "op should be in schedule after cycle 3"
  else
  (* Cycle 4: Schedule -> Execute *)
  let r4 = Risc_pipeline.advance ~completed_ids:[] ~pending_ops:[] r3.pipeline in
  if Option.is_none r4.pipeline.execute_slot then
    fail name "op should be in execute after cycle 4"
  else
  (* Cycle 5: Execute -> Writeback *)
  let r5 = Risc_pipeline.advance ~completed_ids:[] ~pending_ops:[] r4.pipeline in
  if Option.is_none r5.pipeline.writeback_slot then
    fail name "op should be in writeback after cycle 5"
  else
  (* Cycle 6: Writeback -> Complete *)
  let r6 = Risc_pipeline.advance ~completed_ids:[] ~pending_ops:[] r5.pipeline in
  if List.length r6.completed <> 1 then
    fail name (Printf.sprintf "expected 1 completed op, got %d" (List.length r6.completed))
  else
    pass name

let test_pipeline_occupancy () =
  let name = "pipeline_occupancy" in
  let p = Risc_types.create_agent_pipeline "agent-1" in
  let n, d = Risc_types.stage_occupancy p in
  if n <> 0 || d <> 5 then fail name "empty pipeline should be 0/5"
  else pass name

(* ================================================================ *)
(* Pipeline registry tests                                          *)
(* ================================================================ *)

let test_registry_register_unregister () =
  let name = "registry_register_unregister" in
  let reg = Risc_pipeline.create_registry () in
  Risc_pipeline.register_agent reg "agent-a";
  Risc_pipeline.register_agent reg "agent-b";
  if Risc_pipeline.get_pipeline reg "agent-a" = None then
    fail name "agent-a should exist"
  else begin
    Risc_pipeline.unregister_agent reg "agent-a";
    if Risc_pipeline.get_pipeline reg "agent-a" <> None then
      fail name "agent-a should be removed"
    else pass name
  end

let test_registry_tick () =
  let name = "registry_tick" in
  let reg = Risc_pipeline.create_registry () in
  Risc_pipeline.register_agent reg "agent-1";
  let op : Risc_types.micro_op = {
    id = "uop-tick"; parent_task_id = "task-tick";
    instruction = YIELD { reason = "test" };
    stage = Stage_fetch; issued_at = 0.0;
    dependencies = []; result = None;
  } in
  let _completed, _hazards =
    Risc_pipeline.tick ~completed_ids:[] ~pending:[("agent-1", [op])] reg in
  if reg.global_cycle <> 1 then
    fail name "global cycle should be 1 after tick"
  else pass name

let test_registry_status_json () =
  let name = "registry_status_json" in
  let reg = Risc_pipeline.create_registry () in
  Risc_pipeline.register_agent reg "agent-x";
  let json = Risc_pipeline.registry_status reg in
  let cycle = Yojson.Safe.Util.(json |> member "global_cycle" |> to_int) in
  let count = Yojson.Safe.Util.(json |> member "agent_count" |> to_int) in
  if cycle <> 0 then fail name "cycle should be 0"
  else if count <> 1 then fail name "count should be 1"
  else pass name

let test_flush_pipeline () =
  let name = "flush_pipeline" in
  let reg = Risc_pipeline.create_registry () in
  Risc_pipeline.register_agent reg "agent-f";
  let ok = Risc_pipeline.flush_pipeline reg "agent-f" in
  if not ok then fail name "flush should succeed for registered agent"
  else
    let not_ok = Risc_pipeline.flush_pipeline reg "nonexistent" in
    if not_ok then fail name "flush should fail for nonexistent agent"
    else pass name

let test_aggregate_metrics () =
  let name = "aggregate_metrics" in
  let reg = Risc_pipeline.create_registry () in
  Risc_pipeline.register_agent reg "agent-m1";
  Risc_pipeline.register_agent reg "agent-m2";
  let m = Risc_pipeline.aggregate_metrics reg in
  if m.total_ops <> 0 then fail name "total should be 0"
  else pass name

(* ================================================================ *)
(* Decode task tests                                                *)
(* ================================================================ *)

let test_decode_single_instruction () =
  let name = "decode_single_instruction" in
  let instrs = [Risc_types.EXEC { op_id = "op"; tool = "t"; args = `Null }] in
  let ops = Risc_pipeline.decode_task ~task_id:"t-1" ~instructions:instrs in
  if List.length ops <> 1 then
    fail name (Printf.sprintf "expected 1 op, got %d" (List.length ops))
  else
    let op = List.hd ops in
    if op.dependencies <> [] then
      fail name "first op should have no dependencies"
    else pass name

let test_decode_chain () =
  let name = "decode_chain" in
  let instrs = [
    Risc_types.FETCH { task_spec = "bug"; priority = High };
    Risc_types.EXEC { op_id = "fix"; tool = "edit"; args = `Null };
    Risc_types.STORE { key = "result"; value = `String "fixed"; scope = L2_room };
  ] in
  let ops = Risc_pipeline.decode_task ~task_id:"t-chain" ~instructions:instrs in
  if List.length ops <> 3 then
    fail name "expected 3 ops"
  else
    let op2 = List.nth ops 1 in
    let op3 = List.nth ops 2 in
    (* op2 depends on op1, op3 depends on op2 *)
    if op2.dependencies = [] then
      fail name "op2 should depend on op1"
    else if op3.dependencies = [] then
      fail name "op3 should depend on op2"
    else pass name

(* ================================================================ *)
(* Tool dispatch tests                                              *)
(* ================================================================ *)

let test_tool_parse_instruction_exec () =
  let name = "tool_parse_instruction_exec" in
  let json = `Assoc [
    ("mnemonic", `String "EXEC");
    ("op_id", `String "op-42");
    ("tool", `String "my_tool");
    ("args", `Assoc [("x", `Int 1)]);
  ] in
  match Tool_risc.parse_instruction json with
  | Some (EXEC { op_id; tool; _ }) when op_id = "op-42" && tool = "my_tool" ->
      pass name
  | Some _ -> fail name "wrong instruction parsed"
  | None -> fail name "failed to parse EXEC instruction"

let test_tool_parse_instruction_halt () =
  let name = "tool_parse_instruction_halt" in
  let json = `Assoc [
    ("mnemonic", `String "HALT");
    ("exit_code", `Int 0);
  ] in
  match Tool_risc.parse_instruction json with
  | Some (HALT { exit_code = 0; dna = None }) -> pass name
  | _ -> fail name "failed to parse HALT"

let test_tool_dispatch_status () =
  let name = "tool_dispatch_status" in
  let ok, _output = Tool_risc.dispatch "masc_risc_pipeline_status" (`Assoc []) in
  if not ok then fail name "status should succeed"
  else pass name

let test_tool_dispatch_metrics () =
  let name = "tool_dispatch_metrics" in
  let ok, output = Tool_risc.dispatch "masc_risc_metrics" (`Assoc []) in
  if not ok then fail name "metrics should succeed"
  else begin
    let json = Yojson.Safe.from_string output in
    let _stall = Yojson.Safe.Util.(json |> member "stall_rate" |> to_float) in
    pass name
  end

let test_tool_dispatch_register () =
  let name = "tool_dispatch_register" in
  let ok, _ = Tool_risc.dispatch "masc_risc_register_agent"
    (`Assoc [("agent_id", `String "test-agent-1")]) in
  if not ok then fail name "register should succeed"
  else
    let ok2, output = Tool_risc.dispatch "masc_risc_pipeline_status"
      (`Assoc [("agent_id", `String "test-agent-1")]) in
    if not ok2 then fail name ("status for registered agent failed: " ^ output)
    else pass name

let test_tool_dispatch_decode () =
  let name = "tool_dispatch_decode" in
  let ok, output = Tool_risc.dispatch "masc_risc_decode"
    (`Assoc [
      ("task_id", `String "task-decode-test");
      ("instructions", `List [
        `Assoc [("mnemonic", `String "FETCH"); ("task_spec", `String "bug"); ("priority", `Int 1)];
        `Assoc [("mnemonic", `String "EXEC"); ("op_id", `String "fix"); ("tool", `String "edit"); ("args", `Null)];
      ]);
    ]) in
  if not ok then fail name ("decode failed: " ^ output)
  else begin
    let json = Yojson.Safe.from_string output in
    let count = Yojson.Safe.Util.(json |> member "micro_op_count" |> to_int) in
    if count <> 2 then fail name (Printf.sprintf "expected 2 ops, got %d" count)
    else pass name
  end

let test_tool_dispatch_unknown () =
  let name = "tool_dispatch_unknown" in
  let ok, _ = Tool_risc.dispatch "masc_risc_nonexistent" (`Assoc []) in
  if ok then fail name "unknown tool should fail"
  else pass name

let test_spec_start_advances_session () =
  let name = "tool_spec_start_progression" in
  let engine = Speculative_engine.create ~fast_model:dummy_model () in
  let session = Result.get_ok
    (Speculative_engine.branch engine
       ~goal:"g" ~original_query:"q"
       ~candidates:
         [
           Speculative_engine.{ label = "alpha"; prompt = "alpha"; metadata = `Null };
           { label = "beta"; prompt = "beta"; metadata = `Null };
         ]) in
  let simulated = ref false in
  let selected = ref false in
  let ok, output =
    Tool_risc.advance_spec_start
      ~simulate:(fun engine spec_id ->
        simulated := true;
        match Speculative_engine.find_session engine spec_id with
        | None -> Error "missing session"
        | Some current ->
          let outcomes = [
            Speculative_engine.{
              candidate_label = "alpha";
              fast_response = "ok";
              verdict = Mcts_tree.Pass;
              verdict_reason = "ok";
              latency_ms = 1;
              cost_estimate = 0.0;
            };
            {
              candidate_label = "beta";
              fast_response = "no";
              verdict = Mcts_tree.Fail;
              verdict_reason = "bad";
              latency_ms = 1;
              cost_estimate = 0.0;
            };
          ] in
          let updated = { current with state = Verifying; outcomes } in
          Speculative_engine.update_session engine updated;
          Ok updated)
      ~select:(fun engine spec_id ->
        selected := true;
        match Speculative_engine.find_session engine spec_id with
        | None -> Error "missing session"
        | Some current ->
          let updated =
            { current with
              state = Ready_to_commit;
              best_candidate = Some "alpha";
            }
          in
          Speculative_engine.update_session engine updated;
          Ok updated)
      engine session
  in
  if not ok then fail name ("advance_spec_start failed: " ^ output)
  else if not !simulated then fail name "simulate stage not called"
  else if not !selected then fail name "select stage not called"
  else
    let json = Yojson.Safe.from_string output in
    let state = Yojson.Safe.Util.(json |> member "state" |> to_string) in
    let best = Yojson.Safe.Util.(json |> member "best_candidate" |> to_string) in
    if state <> "ready_to_commit" then fail name ("unexpected state: " ^ state)
    else if best <> "alpha" then fail name ("unexpected best candidate: " ^ best)
    else pass name

let test_is_risc_tool () =
  let name = "is_risc_tool" in
  if not (Tool_risc.is_risc_tool "masc_risc_decode") then
    fail name "should recognize RISC tool"
  else if Tool_risc.is_risc_tool "masc_broadcast" then
    fail name "should not match non-RISC tool"
  else pass name

let test_tool_definitions_count () =
  let name = "tool_definitions_count" in
  let count = List.length Tool_risc.tool_definitions in
  if count <> 20 then
    fail name (Printf.sprintf "expected 20 tool definitions, got %d" count)
  else pass name

(* ================================================================ *)
(* Metrics tests                                                    *)
(* ================================================================ *)

let test_ipc_zero () =
  let name = "ipc_zero" in
  let m = Risc_types.create_metrics () in
  if Risc_types.ipc m <> 0.0 then fail name "IPC should be 0.0 with no ops"
  else pass name

let test_ipc_calculation () =
  let name = "ipc_calculation" in
  let m = Risc_types.create_metrics () in
  m.total_ops <- 10;
  m.completed_ops <- 8;
  let v = Risc_types.ipc m in
  if v < 0.79 || v > 0.81 then
    fail name (Printf.sprintf "expected IPC ~0.8, got %f" v)
  else pass name

let test_metrics_to_yojson () =
  let name = "metrics_to_yojson" in
  let m = Risc_types.create_metrics () in
  m.total_ops <- 5;
  m.completed_ops <- 3;
  m.stalled_cycles <- 2;
  let json = Risc_types.metrics_to_yojson m in
  let total = Yojson.Safe.Util.(json |> member "total_ops" |> to_int) in
  if total <> 5 then fail name "total_ops mismatch"
  else pass name

(* ================================================================ *)
(* Hazard string representation tests                               *)
(* ================================================================ *)

let test_hazard_to_string () =
  let name = "hazard_to_string" in
  let h = Risc_types.RAW { producer = "p1"; consumer = "c1"; register = R2_RESULT } in
  let s = Risc_types.hazard_to_string h in
  if not (String.length s > 0) then fail name "should produce non-empty string"
  else pass name

let test_hazard_to_yojson () =
  let name = "hazard_to_yojson" in
  let h = Risc_types.Structural { resource = "llm"; contenders = ["a"; "b"] } in
  let json = Risc_types.hazard_to_yojson h in
  let typ = Yojson.Safe.Util.(json |> member "type" |> to_string) in
  if typ <> "Structural" then fail name "type mismatch"
  else pass name

(* ================================================================ *)
(* Main runner                                                      *)
(* ================================================================ *)

let () =
  Printf.printf "\n=== SWARM-RISC Tests ===\n\n";
  Printf.printf "-- risc_types --\n";
  test_priority_roundtrip ();
  test_cache_scope_roundtrip ();
  test_opcode_unique ();
  test_mnemonic_consistency ();
  test_instruction_to_yojson_roundtrip ();

  Printf.printf "\n-- registers --\n";
  test_register_r0_hardwire ();
  test_register_read_write ();
  test_register_file_to_yojson ();
  test_all_registers_indexed ();

  Printf.printf "\n-- pipeline stages --\n";
  test_stage_names ();
  test_micro_op_to_yojson ();

  Printf.printf "\n-- hazard detection --\n";
  test_raw_hazard_detection ();
  test_no_hazard_independent ();
  test_control_hazard ();
  test_structural_hazard ();

  Printf.printf "\n-- pipeline advance --\n";
  test_pipeline_empty_advance ();
  test_pipeline_single_op_flow ();
  test_pipeline_occupancy ();

  Printf.printf "\n-- pipeline registry --\n";
  test_registry_register_unregister ();
  test_registry_tick ();
  test_registry_status_json ();
  test_flush_pipeline ();
  test_aggregate_metrics ();

  Printf.printf "\n-- decode task --\n";
  test_decode_single_instruction ();
  test_decode_chain ();

  Printf.printf "\n-- tool dispatch --\n";
  test_tool_parse_instruction_exec ();
  test_tool_parse_instruction_halt ();
  test_tool_dispatch_status ();
  test_tool_dispatch_metrics ();
  test_tool_dispatch_register ();
  test_tool_dispatch_decode ();
  test_tool_dispatch_unknown ();
  test_spec_start_advances_session ();
  test_is_risc_tool ();
  test_tool_definitions_count ();

  Printf.printf "\n-- metrics --\n";
  test_ipc_zero ();
  test_ipc_calculation ();
  test_metrics_to_yojson ();

  Printf.printf "\n-- hazard repr --\n";
  test_hazard_to_string ();
  test_hazard_to_yojson ();

  Printf.printf "\n=== All 36 SWARM-RISC tests passed ===\n"
