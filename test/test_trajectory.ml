(** Unit tests for Trajectory module — JSONL trajectory logging. *)

open Masc_mcp

let () =
  (* Ensure RNG is initialized for any code that may need it *)
  ignore (Unix.gettimeofday ())

(* ================================================================ *)
(* Test: tool_cost_estimate returns expected values                   *)
(* ================================================================ *)

let test_tool_cost_known () =
  let cost = Trajectory.tool_cost_estimate "keeper_board_post" in
  Alcotest.(check (float 0.001)) "board_post cost" 0.002 cost

let test_tool_cost_unknown () =
  let cost = Trajectory.tool_cost_estimate "nonexistent_tool" in
  Alcotest.(check (float 0.0001)) "unknown tool default cost" 0.0 cost

let test_tool_cost_bash () =
  let cost = Trajectory.tool_cost_estimate "keeper_bash" in
  Alcotest.(check (float 0.0001)) "bash cost" 0.0001 cost

(* ================================================================ *)
(* Test: gate_decision types                                         *)
(* ================================================================ *)

let test_gate_decision_pass () =
  match Trajectory.Pass with
  | Trajectory.Pass -> ()
  | Trajectory.Reject _ -> Alcotest.fail "Expected Pass"

let test_gate_decision_reject () =
  match Trajectory.Reject "test reason" with
  | Trajectory.Reject reason ->
      Alcotest.(check string) "reject reason" "test reason" reason
  | Trajectory.Pass -> Alcotest.fail "Expected Reject"

(* ================================================================ *)
(* Test: create_accumulator and basic state                          *)
(* ================================================================ *)

let with_tmpdir f =
  let dir = Filename.concat (Filename.get_temp_dir_name ())
    (Printf.sprintf "test_trajectory_%d" (Random.int 100000)) in
  (try Unix.mkdir dir 0o755 with _ -> ());
  Fun.protect ~finally:(fun () ->
    (* Best effort cleanup *)
    ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir)))
  ) (fun () -> f dir)

let test_create_accumulator () =
  with_tmpdir (fun dir ->
    let acc = Trajectory.create_accumulator
      ~masc_root:dir ~keeper_name:"test-keeper"
      ~trace_id:"trace-001" ~generation:0 in
    Alcotest.(check int) "initial turn" 0 acc.Trajectory.turn;
    Alcotest.(check (float 0.0001)) "initial cost" 0.0 acc.Trajectory.total_cost;
    Alcotest.(check int) "initial entries" 0 (List.length acc.Trajectory.entries))

(* ================================================================ *)
(* Test: record_entry updates accumulator                            *)
(* ================================================================ *)

let test_record_entry () =
  with_tmpdir (fun dir ->
    let acc = Trajectory.create_accumulator
      ~masc_root:dir ~keeper_name:"test-keeper"
      ~trace_id:"trace-002" ~generation:0 in
    let entry : Trajectory.tool_call_entry = {
      ts = 1000.0;
      ts_iso = "2026-01-01T00:00:00Z";
      turn = 1;
      round = 0;
      tool_name = "keeper_bash";
      args_json = "{\"command\": \"pwd\"}";
      gate_decision = Trajectory.Pass;
      result = Some "/home/test";
      duration_ms = 50;
      error = None;
      cost_usd = 0.0001;
    } in
    Trajectory.record_entry acc entry;
    Alcotest.(check int) "entries count" 1 (List.length acc.Trajectory.entries);
    Alcotest.(check (float 0.0001)) "total cost" 0.0001 acc.Trajectory.total_cost)

(* ================================================================ *)
(* Test: detect_entropy                                              *)
(* ================================================================ *)

let test_entropy_not_triggered () =
  with_tmpdir (fun dir ->
    let acc = Trajectory.create_accumulator
      ~masc_root:dir ~keeper_name:"test-keeper"
      ~trace_id:"trace-003" ~generation:0 in
    (* Add 1 consecutive call — with +1 for upcoming, count=2 < threshold 3 *)
    let mk_entry tool = { Trajectory.
      ts = 1000.0; ts_iso = ""; turn = 1; round = 0;
      tool_name = tool; args_json = "{}";
      gate_decision = Trajectory.Pass;
      result = Some "ok"; duration_ms = 10;
      error = None; cost_usd = 0.0001;
    } in
    Trajectory.record_entry acc (mk_entry "keeper_bash");
    let entropy = Trajectory.detect_entropy ~threshold:3 acc "keeper_bash" in
    Alcotest.(check bool) "entropy not triggered" true (entropy = None))

let test_entropy_triggered () =
  with_tmpdir (fun dir ->
    let acc = Trajectory.create_accumulator
      ~masc_root:dir ~keeper_name:"test-keeper"
      ~trace_id:"trace-004" ~generation:0 in
    let mk_entry tool = { Trajectory.
      ts = 1000.0; ts_iso = ""; turn = 1; round = 0;
      tool_name = tool; args_json = "{}";
      gate_decision = Trajectory.Pass;
      result = Some "ok"; duration_ms = 10;
      error = None; cost_usd = 0.0001;
    } in
    Trajectory.record_entry acc (mk_entry "keeper_bash");
    Trajectory.record_entry acc (mk_entry "keeper_bash");
    Trajectory.record_entry acc (mk_entry "keeper_bash");
    let entropy = Trajectory.detect_entropy ~threshold:3 acc "keeper_bash" in
    match entropy with
    | Some (_name, count) ->
        Alcotest.(check int) "entropy count" 4 count
    | None -> Alcotest.fail "Expected entropy to be triggered")

(* ================================================================ *)
(* Test: increment_turn                                              *)
(* ================================================================ *)

let test_increment_turn () =
  with_tmpdir (fun dir ->
    let acc = Trajectory.create_accumulator
      ~masc_root:dir ~keeper_name:"test-keeper"
      ~trace_id:"trace-005" ~generation:0 in
    Alcotest.(check int) "turn 0" 0 acc.Trajectory.turn;
    Trajectory.increment_turn acc;
    Alcotest.(check int) "turn 1" 1 acc.Trajectory.turn;
    Trajectory.increment_turn acc;
    Alcotest.(check int) "turn 2" 2 acc.Trajectory.turn)

(* ================================================================ *)
(* Test: finalize creates trajectory record                          *)
(* ================================================================ *)

let test_finalize () =
  with_tmpdir (fun dir ->
    let acc = Trajectory.create_accumulator
      ~masc_root:dir ~keeper_name:"test-keeper"
      ~trace_id:"trace-006" ~generation:0 in
    Trajectory.increment_turn acc;
    let entry : Trajectory.tool_call_entry = {
      ts = 1000.0; ts_iso = "2026-01-01T00:00:00Z";
      turn = 1; round = 0;
      tool_name = "keeper_bash"; args_json = "{}";
      gate_decision = Trajectory.Pass;
      result = Some "ok"; duration_ms = 100;
      error = None; cost_usd = 0.0001;
    } in
    Trajectory.record_entry acc entry;
    let traj = Trajectory.finalize acc Trajectory.Completed in
    Alcotest.(check int) "total turns" 1 traj.Trajectory.total_turns;
    Alcotest.(check int) "total calls" 1 traj.Trajectory.total_tool_calls;
    Alcotest.(check (float 0.0001)) "total cost" 0.0001 traj.Trajectory.total_cost_usd;
    Alcotest.(check string) "trace_id" "trace-006" traj.Trajectory.trace_id)

(* ================================================================ *)
(* Test: outcome_to_string                                           *)
(* ================================================================ *)

let test_outcome_to_string () =
  Alcotest.(check string) "completed" "completed"
    (Trajectory.outcome_to_string Trajectory.Completed);
  Alcotest.(check string) "cost_exceeded" "cost_exceeded"
    (Trajectory.outcome_to_string Trajectory.CostExceeded);
  Alcotest.(check string) "failed" "failed: oops"
    (Trajectory.outcome_to_string (Trajectory.Failed "oops"));
  Alcotest.(check string) "gated" "gated: blocked"
    (Trajectory.outcome_to_string (Trajectory.Gated "blocked"))

(* ================================================================ *)
(* Test: calls_in_current_turn                                       *)
(* ================================================================ *)

let test_calls_in_current_turn () =
  with_tmpdir (fun dir ->
    let acc = Trajectory.create_accumulator
      ~masc_root:dir ~keeper_name:"test-keeper"
      ~trace_id:"trace-007" ~generation:0 in
    Trajectory.increment_turn acc;
    let mk tool = { Trajectory.
      ts = 1000.0; ts_iso = ""; turn = acc.Trajectory.turn; round = 0;
      tool_name = tool; args_json = "{}";
      gate_decision = Trajectory.Pass;
      result = Some "ok"; duration_ms = 10;
      error = None; cost_usd = 0.001;
    } in
    Trajectory.record_entry acc (mk "keeper_bash");
    Trajectory.record_entry acc (mk "keeper_fs_read");
    let count = Trajectory.calls_in_current_turn acc in
    Alcotest.(check int) "calls in turn 1" 2 count)

(* ================================================================ *)
(* Test: task_id binding and propagation                             *)
(* ================================================================ *)

let test_task_id_default_none () =
  with_tmpdir (fun dir ->
    let acc = Trajectory.create_accumulator
      ~masc_root:dir ~keeper_name:"test-keeper"
      ~trace_id:"trace-tid-001" ~generation:0 in
    Alcotest.(check (option string)) "task_id default" None acc.Trajectory.task_id)

let test_set_task_id () =
  with_tmpdir (fun dir ->
    let acc = Trajectory.create_accumulator
      ~masc_root:dir ~keeper_name:"test-keeper"
      ~trace_id:"trace-tid-002" ~generation:0 in
    Trajectory.set_task_id acc "task-042";
    Alcotest.(check (option string)) "task_id set"
      (Some "task-042") acc.Trajectory.task_id)

let test_clear_task_id () =
  with_tmpdir (fun dir ->
    let acc = Trajectory.create_accumulator
      ~masc_root:dir ~keeper_name:"test-keeper"
      ~trace_id:"trace-tid-003" ~generation:0 in
    Trajectory.set_task_id acc "task-042";
    Trajectory.clear_task_id acc;
    Alcotest.(check (option string)) "task_id cleared" None acc.Trajectory.task_id)

let test_finalize_propagates_task_id () =
  with_tmpdir (fun dir ->
    let acc = Trajectory.create_accumulator
      ~masc_root:dir ~keeper_name:"test-keeper"
      ~trace_id:"trace-tid-004" ~generation:0 in
    Trajectory.set_task_id acc "task-099";
    Trajectory.increment_turn acc;
    let traj = Trajectory.finalize acc Trajectory.Completed in
    Alcotest.(check (option string)) "task_id propagated"
      (Some "task-099") traj.Trajectory.task_id)

let test_task_id_in_trajectory_json () =
  with_tmpdir (fun dir ->
    let acc = Trajectory.create_accumulator
      ~masc_root:dir ~keeper_name:"test-keeper"
      ~trace_id:"trace-tid-005" ~generation:0 in
    Trajectory.set_task_id acc "task-json-test";
    let traj = Trajectory.finalize acc Trajectory.Completed in
    let json = Trajectory.trajectory_to_json traj in
    let open Yojson.Safe.Util in
    let task_id_val = json |> member "task_id" in
    match task_id_val with
    | `String s ->
      Alcotest.(check string) "task_id in json" "task-json-test" s
    | _ -> Alcotest.fail "Expected task_id to be a string in trajectory JSON")

let test_task_id_null_when_none () =
  with_tmpdir (fun dir ->
    let acc = Trajectory.create_accumulator
      ~masc_root:dir ~keeper_name:"test-keeper"
      ~trace_id:"trace-tid-006" ~generation:0 in
    let traj = Trajectory.finalize acc Trajectory.Completed in
    let json = Trajectory.trajectory_to_json traj in
    let open Yojson.Safe.Util in
    let task_id_val = json |> member "task_id" in
    match task_id_val with
    | `Null -> ()
    | _ -> Alcotest.fail "Expected task_id to be null when not set")

(* ================================================================ *)
(* Runner                                                            *)
(* ================================================================ *)

let () =
  Alcotest.run "Trajectory" [
    ("tool_cost", [
      Alcotest.test_case "known tool cost" `Quick test_tool_cost_known;
      Alcotest.test_case "unknown tool cost" `Quick test_tool_cost_unknown;
      Alcotest.test_case "bash tool cost" `Quick test_tool_cost_bash;
    ]);
    ("gate_decision", [
      Alcotest.test_case "pass" `Quick test_gate_decision_pass;
      Alcotest.test_case "reject" `Quick test_gate_decision_reject;
    ]);
    ("accumulator", [
      Alcotest.test_case "create" `Quick test_create_accumulator;
      Alcotest.test_case "record_entry" `Quick test_record_entry;
      Alcotest.test_case "increment_turn" `Quick test_increment_turn;
      Alcotest.test_case "calls_in_current_turn" `Quick test_calls_in_current_turn;
    ]);
    ("entropy", [
      Alcotest.test_case "not triggered" `Quick test_entropy_not_triggered;
      Alcotest.test_case "triggered" `Quick test_entropy_triggered;
    ]);
    ("finalize", [
      Alcotest.test_case "finalize completed" `Quick test_finalize;
    ]);
    ("outcome", [
      Alcotest.test_case "outcome_to_string" `Quick test_outcome_to_string;
    ]);
    ("task_id", [
      Alcotest.test_case "default none" `Quick test_task_id_default_none;
      Alcotest.test_case "set_task_id" `Quick test_set_task_id;
      Alcotest.test_case "clear_task_id" `Quick test_clear_task_id;
      Alcotest.test_case "finalize propagates" `Quick test_finalize_propagates_task_id;
      Alcotest.test_case "json with task_id" `Quick test_task_id_in_trajectory_json;
      Alcotest.test_case "json null when none" `Quick test_task_id_null_when_none;
    ]);
  ]
