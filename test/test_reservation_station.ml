(** test_reservation_station.ml — Unit tests for Tomasulo RS + Work-Stealing

    Tests cover:
    - RS entry creation and capacity limits
    - Dependency tracking and CDB broadcast wakeups
    - try_issue (ready entries issued, stall when blocked)
    - complete_entry + internal CDB propagation
    - Cross-agent global_cdb_broadcast
    - gc_completed garbage collection
    - Work-stealing: steal, steal_batch, victim selection
    - JSON serialization (entry, agent_rs, steal_result)
    - Tool dispatch integration tests (Phase 3 MCP)

    @since Phase 3 — SWARM-RISC *)

open Masc_mcp.Reservation_station

(* ================================================================ *)
(* Test Helpers                                                      *)
(* ================================================================ *)

let check msg cond =
  if not cond then failwith (Printf.sprintf "FAIL: %s" msg)


let pass_count = ref 0
let fail_count = ref 0

let run_test name f =
  try
    f ();
    incr pass_count;
    Printf.printf "  ✓ %s\n%!" name
  with e ->
    incr fail_count;
    Printf.printf "  ✗ %s: %s\n%!" name (Printexc.to_string e)

(** Make a simple EXEC instruction for testing *)
let exec_instr op_id =
  Masc_mcp.Risc_types.EXEC { op_id; tool = "test_tool"; args = `Null }

(* ================================================================ *)
(* RS Entry Creation Tests                                           *)
(* ================================================================ *)

let test_add_entry_ok () =
  let rs = create_agent_rs ~capacity:4 "agent-1" in
  match add_entry rs ~op_id:"op-1" ~instruction:(exec_instr "op-1")
          ~parent_task_id:"task-1" ~operand_tags:[] with
  | Ok entry ->
      check "op_id matches" (entry.op_id = "op-1");
      check "not issued" (not entry.issued);
      check "no result" (Option.is_none entry.result);
      check "total_added is 1" (rs.total_added = 1)
  | Error msg -> failwith ("add_entry should succeed: " ^ msg)

let test_add_entry_capacity_full () =
  let rs = create_agent_rs ~capacity:1 "agent-cap" in
  ignore (add_entry rs ~op_id:"op-1" ~instruction:(exec_instr "op-1")
            ~parent_task_id:"t" ~operand_tags:[]);
  match add_entry rs ~op_id:"op-2" ~instruction:(exec_instr "op-2")
          ~parent_task_id:"t" ~operand_tags:[] with
  | Error _ -> ()  (* Expected *)
  | Ok _ -> failwith "should reject when RS is full"

let test_has_capacity () =
  let rs = create_agent_rs ~capacity:2 "agent-hc" in
  check "empty has capacity" (has_capacity rs);
  ignore (add_entry rs ~op_id:"op-1" ~instruction:(exec_instr "op-1")
            ~parent_task_id:"t" ~operand_tags:[]);
  check "1/2 has capacity" (has_capacity rs);
  ignore (add_entry rs ~op_id:"op-2" ~instruction:(exec_instr "op-2")
            ~parent_task_id:"t" ~operand_tags:[]);
  check "2/2 no capacity" (not (has_capacity rs))

let test_pending_count () =
  let rs = create_agent_rs ~capacity:4 "agent-pc" in
  ignore (add_entry rs ~op_id:"op-1" ~instruction:(exec_instr "op-1")
            ~parent_task_id:"t" ~operand_tags:[]);
  ignore (add_entry rs ~op_id:"op-2" ~instruction:(exec_instr "op-2")
            ~parent_task_id:"t" ~operand_tags:["op-1"]);
  check "pending is 2" (pending_count rs = 2)

(* ================================================================ *)
(* is_ready and Dependency Tests                                     *)
(* ================================================================ *)

let test_is_ready_no_deps () =
  let rs = create_agent_rs "agent-rdy" in
  match add_entry rs ~op_id:"op-1" ~instruction:(exec_instr "op-1")
          ~parent_task_id:"t" ~operand_tags:[] with
  | Ok entry -> check "no deps → ready" (is_ready entry)
  | Error msg -> failwith msg

let test_is_ready_with_unresolved_deps () =
  let rs = create_agent_rs "agent-dep" in
  match add_entry rs ~op_id:"op-2" ~instruction:(exec_instr "op-2")
          ~parent_task_id:"t" ~operand_tags:["op-1"] with
  | Ok entry -> check "unresolved dep → not ready" (not (is_ready entry))
  | Error msg -> failwith msg

let test_remaining_deps () =
  let rs = create_agent_rs "agent-rem" in
  match add_entry rs ~op_id:"op-3" ~instruction:(exec_instr "op-3")
          ~parent_task_id:"t" ~operand_tags:["dep-a"; "dep-b"] with
  | Ok entry ->
      let deps = remaining_deps entry in
      check "2 remaining deps" (List.length deps = 2)
  | Error msg -> failwith msg

(* ================================================================ *)
(* CDB Broadcast Tests                                               *)
(* ================================================================ *)

let test_cdb_broadcast_resolves_dep () =
  let rs = create_agent_rs "agent-cdb" in
  (* Add op-1 (no deps, will be completed) *)
  ignore (add_entry rs ~op_id:"op-1" ~instruction:(exec_instr "op-1")
            ~parent_task_id:"t" ~operand_tags:[]);
  (* Add op-2 depends on op-1 *)
  ignore (add_entry rs ~op_id:"op-2" ~instruction:(exec_instr "op-2")
            ~parent_task_id:"t" ~operand_tags:["op-1"]);
  (* op-2 should NOT be ready before CDB *)
  let op2_before = List.find (fun e -> e.op_id = "op-2") rs.entries in
  check "op-2 not ready before CDB" (not (is_ready op2_before));
  (* CDB broadcast for op-1 *)
  let newly_ready = cdb_broadcast rs ~completed_op_id:"op-1" ~result:(`String "done") in
  check "1 newly ready" (newly_ready = 1);
  check "cdb_wakeups incremented" (rs.cdb_wakeups = 1);
  (* op-2 should now be ready *)
  let op2_after = List.find (fun e -> e.op_id = "op-2") rs.entries in
  check "op-2 ready after CDB" (is_ready op2_after)

let test_cdb_broadcast_no_match () =
  let rs = create_agent_rs "agent-nomatch" in
  ignore (add_entry rs ~op_id:"op-1" ~instruction:(exec_instr "op-1")
            ~parent_task_id:"t" ~operand_tags:["unrelated-dep"]);
  let newly_ready = cdb_broadcast rs ~completed_op_id:"other-op" ~result:`Null in
  check "0 newly ready (no match)" (newly_ready = 0)

let test_cdb_broadcast_multiple_deps () =
  let rs = create_agent_rs "agent-multi" in
  (* op-3 depends on both op-1 and op-2 *)
  ignore (add_entry rs ~op_id:"op-3" ~instruction:(exec_instr "op-3")
            ~parent_task_id:"t" ~operand_tags:["op-1"; "op-2"]);
  (* Resolve op-1 *)
  let r1 = cdb_broadcast rs ~completed_op_id:"op-1" ~result:`Null in
  check "op-3 not yet ready (1 resolved)" (r1 = 0);
  (* Resolve op-2 → now all deps resolved *)
  let r2 = cdb_broadcast rs ~completed_op_id:"op-2" ~result:`Null in
  check "op-3 now ready (both resolved)" (r2 = 1)

(* ================================================================ *)
(* Issue Tests                                                       *)
(* ================================================================ *)

let test_try_issue_ready () =
  let rs = create_agent_rs "agent-iss" in
  ignore (add_entry rs ~op_id:"op-1" ~instruction:(exec_instr "op-1")
            ~parent_task_id:"t" ~operand_tags:[]);
  match try_issue rs with
  | Some entry ->
      check "issued op-1" (entry.op_id = "op-1");
      check "entry.issued is true" entry.issued;
      check "total_issued is 1" (rs.total_issued = 1)
  | None -> failwith "should issue ready entry"

let test_try_issue_stall () =
  let rs = create_agent_rs "agent-stall" in
  ignore (add_entry rs ~op_id:"op-1" ~instruction:(exec_instr "op-1")
            ~parent_task_id:"t" ~operand_tags:["missing-dep"]);
  match try_issue rs with
  | None ->
      check "stall_cycles incremented" (rs.stall_cycles = 1)
  | Some _ -> failwith "should stall with unresolved dep"

let test_try_issue_fifo () =
  let rs = create_agent_rs "agent-fifo" in
  (* Add two ready entries; oldest should be issued first *)
  ignore (add_entry rs ~op_id:"op-old" ~instruction:(exec_instr "op-old")
            ~parent_task_id:"t" ~operand_tags:[]);
  Unix.sleepf 0.01;
  ignore (add_entry rs ~op_id:"op-new" ~instruction:(exec_instr "op-new")
            ~parent_task_id:"t" ~operand_tags:[]);
  match try_issue rs with
  | Some entry -> check "oldest issued first" (entry.op_id = "op-old")
  | None -> failwith "should issue"

let test_try_issue_skip_already_issued () =
  let rs = create_agent_rs "agent-skip" in
  ignore (add_entry rs ~op_id:"op-1" ~instruction:(exec_instr "op-1")
            ~parent_task_id:"t" ~operand_tags:[]);
  ignore (add_entry rs ~op_id:"op-2" ~instruction:(exec_instr "op-2")
            ~parent_task_id:"t" ~operand_tags:[]);
  (* Issue first *)
  ignore (try_issue rs);
  (* Issue again should get op-2 *)
  match try_issue rs with
  | Some entry -> check "second issue is op-2" (entry.op_id = "op-2")
  | None -> failwith "should issue second entry"

(* ================================================================ *)
(* Complete + Internal CDB Tests                                     *)
(* ================================================================ *)

let test_complete_entry_ok () =
  let rs = create_agent_rs "agent-comp" in
  ignore (add_entry rs ~op_id:"op-1" ~instruction:(exec_instr "op-1")
            ~parent_task_id:"t" ~operand_tags:[]);
  ignore (try_issue rs);
  match complete_entry rs ~op_id:"op-1" ~result:(`String "done") with
  | Ok () -> check "total_completed is 1" (rs.total_completed = 1)
  | Error msg -> failwith ("complete should succeed: " ^ msg)

let test_complete_entry_not_issued () =
  let rs = create_agent_rs "agent-niss" in
  ignore (add_entry rs ~op_id:"op-1" ~instruction:(exec_instr "op-1")
            ~parent_task_id:"t" ~operand_tags:[]);
  match complete_entry rs ~op_id:"op-1" ~result:`Null with
  | Error _ -> ()  (* Expected: not issued yet *)
  | Ok () -> failwith "should fail for non-issued entry"

let test_complete_triggers_internal_cdb () =
  let rs = create_agent_rs "agent-icdb" in
  (* op-1 has no deps, op-2 depends on op-1 *)
  ignore (add_entry rs ~op_id:"op-1" ~instruction:(exec_instr "op-1")
            ~parent_task_id:"t" ~operand_tags:[]);
  ignore (add_entry rs ~op_id:"op-2" ~instruction:(exec_instr "op-2")
            ~parent_task_id:"t" ~operand_tags:["op-1"]);
  (* Issue and complete op-1 *)
  ignore (try_issue rs);
  ignore (complete_entry rs ~op_id:"op-1" ~result:(`String "result-1"));
  (* op-2 should now be ready due to internal CDB *)
  let op2 = List.find (fun e -> e.op_id = "op-2") rs.entries in
  check "op-2 ready after internal CDB" (is_ready op2)

(* ================================================================ *)
(* GC Completed Tests                                                *)
(* ================================================================ *)

let test_gc_completed () =
  let rs = create_agent_rs "agent-gc" in
  ignore (add_entry rs ~op_id:"op-1" ~instruction:(exec_instr "op-1")
            ~parent_task_id:"t" ~operand_tags:[]);
  ignore (add_entry rs ~op_id:"op-2" ~instruction:(exec_instr "op-2")
            ~parent_task_id:"t" ~operand_tags:[]);
  ignore (try_issue rs);
  ignore (complete_entry rs ~op_id:"op-1" ~result:`Null);
  let removed = gc_completed rs in
  check "1 completed removed" (List.length removed = 1);
  check "1 entry remains" (List.length rs.entries = 1)

(* ================================================================ *)
(* Stealable + steal_entry Tests                                     *)
(* ================================================================ *)

let test_list_stealable () =
  let rs = create_agent_rs "agent-steal" in
  (* op-1: ready (no deps) *)
  ignore (add_entry rs ~op_id:"op-1" ~instruction:(exec_instr "op-1")
            ~parent_task_id:"t" ~operand_tags:[]);
  (* op-2: not ready (depends on missing dep) *)
  ignore (add_entry rs ~op_id:"op-2" ~instruction:(exec_instr "op-2")
            ~parent_task_id:"t" ~operand_tags:["missing"]);
  let stealable = list_stealable rs in
  check "1 stealable entry" (List.length stealable = 1);
  check "stealable is op-1" ((List.hd stealable).op_id = "op-1")

let test_steal_entry_removes () =
  let rs = create_agent_rs "agent-srem" in
  ignore (add_entry rs ~op_id:"op-1" ~instruction:(exec_instr "op-1")
            ~parent_task_id:"t" ~operand_tags:[]);
  match steal_entry rs ~op_id:"op-1" with
  | Some entry ->
      check "stolen op_id" (entry.op_id = "op-1");
      check "entry removed from RS" (List.length rs.entries = 0);
      check "total_stolen incremented" (rs.total_stolen = 1)
  | None -> failwith "should steal ready entry"

let test_steal_entry_issued_blocked () =
  let rs = create_agent_rs "agent-sblk" in
  ignore (add_entry rs ~op_id:"op-1" ~instruction:(exec_instr "op-1")
            ~parent_task_id:"t" ~operand_tags:[]);
  ignore (try_issue rs);
  match steal_entry rs ~op_id:"op-1" with
  | None -> ()  (* Expected: cannot steal issued entry *)
  | Some _ -> failwith "should not steal issued entry"

(* ================================================================ *)
(* Global Scheduler Tests                                            *)
(* ================================================================ *)

let test_global_scheduler_get_or_create () =
  let sched = create_scheduler () in
  let rs1 = get_or_create_rs sched ~agent_id:"a1" () in
  let rs2 = get_or_create_rs sched ~agent_id:"a1" () in
  check "same RS returned" (rs1 == rs2);
  check "1 agent" (Hashtbl.length sched.agents = 1)

let test_global_cdb_broadcast () =
  let sched = create_scheduler () in
  let rs_a = get_or_create_rs sched ~agent_id:"a1" () in
  let rs_b = get_or_create_rs sched ~agent_id:"a2" () in
  (* Agent A adds op-1 (no deps) *)
  ignore (add_entry rs_a ~op_id:"op-1" ~instruction:(exec_instr "op-1")
            ~parent_task_id:"t" ~operand_tags:[]);
  (* Agent B adds op-2 (depends on op-1 from agent A) *)
  ignore (add_entry rs_b ~op_id:"op-2" ~instruction:(exec_instr "op-2")
            ~parent_task_id:"t" ~operand_tags:["op-1"]);
  (* Global CDB for op-1 *)
  let wakeups = global_cdb_broadcast sched ~completed_op_id:"op-1"
                  ~result:(`String "result-a") in
  check "at least 1 cross-agent wakeup" (wakeups >= 1);
  check "global_cdb_events incremented" (sched.global_cdb_events = 1);
  (* Agent B's op-2 should now be ready *)
  let op2 = List.find (fun e -> e.op_id = "op-2") rs_b.entries in
  check "op-2 ready after global CDB" (is_ready op2)

let test_aggregate_metrics () =
  let sched = create_scheduler () in
  let rs_a = get_or_create_rs sched ~agent_id:"m1" () in
  let rs_b = get_or_create_rs sched ~agent_id:"m2" () in
  ignore (add_entry rs_a ~op_id:"op-a1" ~instruction:(exec_instr "op-a1")
            ~parent_task_id:"t" ~operand_tags:[]);
  ignore (add_entry rs_b ~op_id:"op-b1" ~instruction:(exec_instr "op-b1")
            ~parent_task_id:"t" ~operand_tags:[]);
  let json = aggregate_metrics sched in
  let total_added = Yojson.Safe.Util.(json |> member "total_added" |> to_int) in
  check "total_added is 2" (total_added = 2)

(* ================================================================ *)
(* Work-Stealing Module Tests                                        *)
(* ================================================================ *)

let test_steal_from_busiest () =
  let sched = create_scheduler () in
  let rs_a = get_or_create_rs sched ~agent_id:"victim" () in
  let _rs_t = get_or_create_rs sched ~agent_id:"thief" () in
  (* Give victim 3 ready entries *)
  ignore (add_entry rs_a ~op_id:"v-1" ~instruction:(exec_instr "v-1")
            ~parent_task_id:"t" ~operand_tags:[]);
  ignore (add_entry rs_a ~op_id:"v-2" ~instruction:(exec_instr "v-2")
            ~parent_task_id:"t" ~operand_tags:[]);
  ignore (add_entry rs_a ~op_id:"v-3" ~instruction:(exec_instr "v-3")
            ~parent_task_id:"t" ~operand_tags:[]);
  match Masc_mcp.Work_stealing.steal sched ~thief_id:"thief" with
  | Masc_mcp.Work_stealing.Stolen { victim_id; thief_id; _ } ->
      check "victim is correct" (victim_id = "victim");
      check "thief is correct" (thief_id = "thief");
      check "victim lost 1 entry" (List.length rs_a.entries = 2)
  | other -> failwith ("expected Stolen, got " ^
      Masc_mcp.Work_stealing.steal_result_to_string other)

let test_steal_self_only () =
  let sched = create_scheduler () in
  let _rs = get_or_create_rs sched ~agent_id:"lonely" () in
  match Masc_mcp.Work_stealing.steal sched ~thief_id:"lonely" with
  | Masc_mcp.Work_stealing.Self_only -> ()
  | other -> failwith ("expected Self_only, got " ^
      Masc_mcp.Work_stealing.steal_result_to_string other)

let test_steal_no_victim () =
  let sched = create_scheduler () in
  let _rs_a = get_or_create_rs sched ~agent_id:"idle-1" () in
  let _rs_b = get_or_create_rs sched ~agent_id:"idle-2" () in
  match Masc_mcp.Work_stealing.steal sched ~thief_id:"idle-1" with
  | Masc_mcp.Work_stealing.No_victim -> ()
  | other -> failwith ("expected No_victim, got " ^
      Masc_mcp.Work_stealing.steal_result_to_string other)

let test_steal_thief_busy () =
  let sched = create_scheduler () in
  let rs_v = get_or_create_rs sched ~agent_id:"v-busy" () in
  let rs_t = get_or_create_rs sched ~agent_id:"t-busy" ~capacity:1 () in
  (* Give victim work *)
  ignore (add_entry rs_v ~op_id:"w-1" ~instruction:(exec_instr "w-1")
            ~parent_task_id:"t" ~operand_tags:[]);
  (* Fill thief's RS *)
  ignore (add_entry rs_t ~op_id:"t-1" ~instruction:(exec_instr "t-1")
            ~parent_task_id:"t" ~operand_tags:[]);
  match Masc_mcp.Work_stealing.steal sched ~thief_id:"t-busy" with
  | Masc_mcp.Work_stealing.Thief_busy -> ()
  | other -> failwith ("expected Thief_busy, got " ^
      Masc_mcp.Work_stealing.steal_result_to_string other)

let test_steal_batch () =
  let sched = create_scheduler () in
  let rs_v = get_or_create_rs sched ~agent_id:"batch-v" () in
  let _rs_t = get_or_create_rs sched ~agent_id:"batch-t" () in
  (* Give victim 5 ready entries *)
  for i = 1 to 5 do
    let id = Printf.sprintf "bv-%d" i in
    ignore (add_entry rs_v ~op_id:id ~instruction:(exec_instr id)
              ~parent_task_id:"t" ~operand_tags:[]);
  done;
  let results = Masc_mcp.Work_stealing.steal_batch sched
                  ~thief_id:"batch-t" ~max_count:3 in
  check "stole 3 entries" (List.length results = 3)

let test_steal_overview_json () =
  let sched = create_scheduler () in
  let _rs = get_or_create_rs sched ~agent_id:"ov-1" () in
  let json = Masc_mcp.Work_stealing.steal_overview sched in
  match json with
  | `Assoc fields ->
      check "has agents field" (List.assoc_opt "agents" fields <> None);
      check "has global_cdb_events" (List.assoc_opt "global_cdb_events" fields <> None)
  | _ -> failwith "expected Assoc"

(* ================================================================ *)
(* JSON Serialization Tests                                          *)
(* ================================================================ *)

let test_entry_to_yojson () =
  let rs = create_agent_rs "agent-json-e" in
  match add_entry rs ~op_id:"j-1" ~instruction:(exec_instr "j-1")
          ~parent_task_id:"task-j" ~operand_tags:["dep-a"] with
  | Ok entry ->
      let json = entry_to_yojson entry in
      let op = Yojson.Safe.Util.(json |> member "op_id" |> to_string) in
      let ready = Yojson.Safe.Util.(json |> member "ready" |> to_bool) in
      check "op_id in JSON" (op = "j-1");
      check "not ready in JSON" (not ready)
  | Error msg -> failwith msg

let test_agent_rs_to_yojson () =
  let rs = create_agent_rs ~capacity:4 "agent-json-rs" in
  ignore (add_entry rs ~op_id:"r-1" ~instruction:(exec_instr "r-1")
            ~parent_task_id:"t" ~operand_tags:[]);
  let json = agent_rs_to_yojson rs in
  let cap = Yojson.Safe.Util.(json |> member "capacity" |> to_int) in
  let count = Yojson.Safe.Util.(json |> member "entry_count" |> to_int) in
  check "capacity 4" (cap = 4);
  check "entry_count 1" (count = 1)

let test_steal_result_to_yojson () =
  let json = Masc_mcp.Work_stealing.steal_result_to_yojson
               Masc_mcp.Work_stealing.No_victim in
  let status = Yojson.Safe.Util.(json |> member "status" |> to_string) in
  check "status is no_victim" (status = "no_victim")

(* ================================================================ *)
(* Tool Dispatch Integration Tests (Phase 3 MCP)                    *)
(* ================================================================ *)

(** Helper: parse dispatch result JSON *)
let dispatch_json tool_name args =
  let (ok, body) = Masc_mcp.Tool_risc.dispatch tool_name args in
  (ok, Yojson.Safe.from_string body)

let json_member key json =
  Yojson.Safe.Util.member key json

let json_string json =
  Yojson.Safe.Util.to_string json

let json_int json =
  Yojson.Safe.Util.to_int json

let json_bool json =
  Yojson.Safe.Util.to_bool json

let test_dispatch_rs_add () =
  let args = `Assoc [
    ("agent_id", `String "dispatch-agent-1");
    ("op_id", `String "d-op-1");
    ("parent_task_id", `String "d-task-1");
    ("instruction", `Assoc [
      ("mnemonic", `String "EXEC");
      ("op_id", `String "d-op-1");
      ("tool", `String "test_tool");
      ("args", `Null);
    ]);
    ("operand_tags", `List []);
  ] in
  let (ok, json) = dispatch_json "masc_risc_rs_add" args in
  check "rs_add ok" ok;
  check "added is true" (json_bool (json_member "added" json))

let test_dispatch_rs_add_missing_instruction () =
  let args = `Assoc [
    ("agent_id", `String "dispatch-agent-2");
    ("op_id", `String "d-op-bad");
  ] in
  let (ok, _body) = Masc_mcp.Tool_risc.dispatch "masc_risc_rs_add" args in
  check "rs_add fails without instruction" (not ok)

let test_dispatch_rs_status_aggregate () =
  let (ok, json) = dispatch_json "masc_risc_rs_status" (`Assoc []) in
  check "rs_status ok" ok;
  check "has agent_count" (json_member "agent_count" json <> `Null)

let test_dispatch_rs_status_agent () =
  (* First add an entry so the agent exists *)
  let agent = "status-test-agent" in
  let add_args = `Assoc [
    ("agent_id", `String agent);
    ("op_id", `String "st-op-1");
    ("instruction", `Assoc [
      ("mnemonic", `String "YIELD");
      ("reason", `String "test");
    ]);
    ("operand_tags", `List []);
  ] in
  ignore (Masc_mcp.Tool_risc.dispatch "masc_risc_rs_add" add_args);
  let (ok, json) = dispatch_json "masc_risc_rs_status"
    (`Assoc [("agent_id", `String agent)]) in
  check "status ok" ok;
  check "agent_id matches" (json_string (json_member "agent_id" json) = agent)

let test_dispatch_rs_issue () =
  let agent = "issue-test-agent" in
  let add_args = `Assoc [
    ("agent_id", `String agent);
    ("op_id", `String "iss-op-1");
    ("instruction", `Assoc [
      ("mnemonic", `String "EXEC");
      ("op_id", `String "iss-op-1");
      ("tool", `String "t");
      ("args", `Null);
    ]);
    ("operand_tags", `List []);
  ] in
  ignore (Masc_mcp.Tool_risc.dispatch "masc_risc_rs_add" add_args);
  let (ok, json) = dispatch_json "masc_risc_rs_issue"
    (`Assoc [("agent_id", `String agent)]) in
  check "rs_issue ok" ok;
  check "issued is true" (json_bool (json_member "issued" json))

let test_dispatch_rs_issue_stall () =
  let agent = "stall-issue-agent" in
  let add_args = `Assoc [
    ("agent_id", `String agent);
    ("op_id", `String "stall-op-1");
    ("instruction", `Assoc [
      ("mnemonic", `String "EXEC");
      ("op_id", `String "stall-op-1");
      ("tool", `String "t");
      ("args", `Null);
    ]);
    ("operand_tags", `List [`String "missing-dep"]);
  ] in
  ignore (Masc_mcp.Tool_risc.dispatch "masc_risc_rs_add" add_args);
  let (ok, json) = dispatch_json "masc_risc_rs_issue"
    (`Assoc [("agent_id", `String agent)]) in
  check "rs_issue ok (stall is ok)" ok;
  check "issued is false" (not (json_bool (json_member "issued" json)))

let test_dispatch_rs_complete_and_cdb () =
  let agent = "comp-cdb-agent" in
  (* Add op-1 (no deps) *)
  ignore (Masc_mcp.Tool_risc.dispatch "masc_risc_rs_add" (`Assoc [
    ("agent_id", `String agent);
    ("op_id", `String "comp-op-1");
    ("instruction", `Assoc [
      ("mnemonic", `String "EXEC");
      ("op_id", `String "comp-op-1");
      ("tool", `String "t");
      ("args", `Null);
    ]);
    ("operand_tags", `List []);
  ]));
  (* Issue op-1 *)
  ignore (Masc_mcp.Tool_risc.dispatch "masc_risc_rs_issue"
    (`Assoc [("agent_id", `String agent)]));
  (* Complete op-1 *)
  let (ok, json) = dispatch_json "masc_risc_rs_complete" (`Assoc [
    ("agent_id", `String agent);
    ("op_id", `String "comp-op-1");
    ("result", `String "success");
  ]) in
  check "complete ok" ok;
  check "completed is true" (json_bool (json_member "completed" json));
  let wakeups = json_int (json_member "cdb_wakeups" json) in
  check "cdb_wakeups >= 0" (wakeups >= 0)

let test_dispatch_steal () =
  let victim = "steal-dispatch-victim" in
  let thief = "steal-dispatch-thief" in
  (* Give victim ready work *)
  ignore (Masc_mcp.Tool_risc.dispatch "masc_risc_rs_add" (`Assoc [
    ("agent_id", `String victim);
    ("op_id", `String "steal-v-1");
    ("instruction", `Assoc [
      ("mnemonic", `String "EXEC");
      ("op_id", `String "steal-v-1");
      ("tool", `String "t");
      ("args", `Null);
    ]);
    ("operand_tags", `List []);
  ]));
  let (ok, json) = dispatch_json "masc_risc_steal"
    (`Assoc [("thief_id", `String thief)]) in
  check "steal dispatch ok" ok;
  let status = json_string (json_member "status" json) in
  (* Could be "stolen" or "no_victim" depending on global scheduler state *)
  check "valid steal status" (status = "stolen" || status = "no_victim" || status = "self_only")

let test_dispatch_ooo_metrics () =
  let (ok, json) = dispatch_json "masc_risc_ooo_metrics" (`Assoc []) in
  check "ooo_metrics ok" ok;
  check "has reservation_stations" (json_member "reservation_stations" json <> `Null);
  check "has work_stealing" (json_member "work_stealing" json <> `Null)

(* ================================================================ *)
(* Main                                                              *)
(* ================================================================ *)

let () =
  Printf.printf "\n=== Reservation Station + Work-Stealing Tests ===\n\n";

  Printf.printf "-- RS Entry Creation --\n";
  run_test "add entry ok" test_add_entry_ok;
  run_test "add entry capacity full" test_add_entry_capacity_full;
  run_test "has_capacity" test_has_capacity;
  run_test "pending_count" test_pending_count;

  Printf.printf "\n-- Dependency / Ready --\n";
  run_test "is_ready no deps" test_is_ready_no_deps;
  run_test "is_ready with unresolved deps" test_is_ready_with_unresolved_deps;
  run_test "remaining_deps" test_remaining_deps;

  Printf.printf "\n-- CDB Broadcast --\n";
  run_test "CDB resolves dependency" test_cdb_broadcast_resolves_dep;
  run_test "CDB no match" test_cdb_broadcast_no_match;
  run_test "CDB multiple deps" test_cdb_broadcast_multiple_deps;

  Printf.printf "\n-- Issue --\n";
  run_test "try_issue ready" test_try_issue_ready;
  run_test "try_issue stall" test_try_issue_stall;
  run_test "try_issue FIFO ordering" test_try_issue_fifo;
  run_test "try_issue skip already issued" test_try_issue_skip_already_issued;

  Printf.printf "\n-- Complete + Internal CDB --\n";
  run_test "complete_entry ok" test_complete_entry_ok;
  run_test "complete_entry not issued" test_complete_entry_not_issued;
  run_test "complete triggers internal CDB" test_complete_triggers_internal_cdb;

  Printf.printf "\n-- GC Completed --\n";
  run_test "gc_completed" test_gc_completed;

  Printf.printf "\n-- Stealable + steal_entry --\n";
  run_test "list_stealable" test_list_stealable;
  run_test "steal_entry removes" test_steal_entry_removes;
  run_test "steal_entry blocked if issued" test_steal_entry_issued_blocked;

  Printf.printf "\n-- Global Scheduler --\n";
  run_test "get_or_create_rs idempotent" test_global_scheduler_get_or_create;
  run_test "global_cdb_broadcast cross-agent" test_global_cdb_broadcast;
  run_test "aggregate_metrics" test_aggregate_metrics;

  Printf.printf "\n-- Work-Stealing --\n";
  run_test "steal from busiest" test_steal_from_busiest;
  run_test "steal self_only" test_steal_self_only;
  run_test "steal no_victim" test_steal_no_victim;
  run_test "steal thief_busy" test_steal_thief_busy;
  run_test "steal_batch" test_steal_batch;
  run_test "steal_overview JSON" test_steal_overview_json;

  Printf.printf "\n-- JSON Serialization --\n";
  run_test "entry_to_yojson" test_entry_to_yojson;
  run_test "agent_rs_to_yojson" test_agent_rs_to_yojson;
  run_test "steal_result_to_yojson" test_steal_result_to_yojson;

  Printf.printf "\n-- Tool Dispatch (Phase 3 MCP integration) --\n";
  run_test "dispatch rs_add" test_dispatch_rs_add;
  run_test "dispatch rs_add missing instruction" test_dispatch_rs_add_missing_instruction;
  run_test "dispatch rs_status aggregate" test_dispatch_rs_status_aggregate;
  run_test "dispatch rs_status per-agent" test_dispatch_rs_status_agent;
  run_test "dispatch rs_issue" test_dispatch_rs_issue;
  run_test "dispatch rs_issue stall" test_dispatch_rs_issue_stall;
  run_test "dispatch rs_complete + CDB" test_dispatch_rs_complete_and_cdb;
  run_test "dispatch steal" test_dispatch_steal;
  run_test "dispatch ooo_metrics" test_dispatch_ooo_metrics;

  Printf.printf "\n=== Results: %d passed, %d failed ===\n\n" !pass_count !fail_count;
  if !fail_count > 0 then exit 1
