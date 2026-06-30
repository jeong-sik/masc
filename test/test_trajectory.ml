(** Unit tests for Trajectory module — JSONL trajectory logging. *)

open Masc

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
  let cost = Trajectory.tool_cost_estimate "tool_execute" in
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
    Fs_compat.remove_tree dir
  ) (fun () -> f dir)

let test_create_accumulator () =
  with_tmpdir (fun dir ->
    let acc = Trajectory.create_accumulator
      ~masc_root:dir ~keeper_name:"test-keeper"
      ~trace_id:"trace-001" ~generation:0 () in
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
      ~trace_id:"trace-002" ~generation:0 () in
    let entry : Trajectory.tool_call_entry = {
      ts = 1000.0;
      ts_iso = "2026-01-01T00:00:00Z";
      turn = 1;
      round = 0;
      tool_name = "tool_execute";
      args_json = "{\"command\": \"pwd\"}";
      gate_decision = Trajectory.Pass;
      result = Some "/home/test";
      duration_ms = 50;
      error = None;
      cost_usd = 0.0001;
      execution_id = Some "exec-1000-0001";
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
      ~trace_id:"trace-003" ~generation:0 () in
    (* Add 1 consecutive call — with +1 for upcoming, count=2 < threshold 3 *)
    let mk_entry tool = { Trajectory.
      ts = 1000.0; ts_iso = ""; turn = 1; round = 0;
      tool_name = tool; args_json = "{}";
      gate_decision = Trajectory.Pass;
      result = Some "ok"; duration_ms = 10;
      error = None; cost_usd = 0.0001;
      execution_id = None;
    } in
    Trajectory.record_entry acc (mk_entry "tool_execute");
    let entropy = Trajectory.detect_entropy ~threshold:3 acc "tool_execute" in
    Alcotest.(check bool) "entropy not triggered" true (entropy = None))

let test_entropy_triggered () =
  with_tmpdir (fun dir ->
    let acc = Trajectory.create_accumulator
      ~masc_root:dir ~keeper_name:"test-keeper"
      ~trace_id:"trace-004" ~generation:0 () in
    let mk_entry tool = { Trajectory.
      ts = 1000.0; ts_iso = ""; turn = 1; round = 0;
      tool_name = tool; args_json = "{}";
      gate_decision = Trajectory.Pass;
      result = Some "ok"; duration_ms = 10;
      error = None; cost_usd = 0.0001;
      execution_id = None;
    } in
    Trajectory.record_entry acc (mk_entry "tool_execute");
    Trajectory.record_entry acc (mk_entry "tool_execute");
    Trajectory.record_entry acc (mk_entry "tool_execute");
    let entropy = Trajectory.detect_entropy ~threshold:3 acc "tool_execute" in
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
      ~trace_id:"trace-005" ~generation:0 () in
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
      ~trace_id:"trace-006" ~generation:0 () in
    Trajectory.increment_turn acc;
    let entry : Trajectory.tool_call_entry = {
      ts = 1000.0; ts_iso = "2026-01-01T00:00:00Z";
      turn = 1; round = 0;
      tool_name = "tool_execute"; args_json = "{}";
      gate_decision = Trajectory.Pass;
      result = Some "ok"; duration_ms = 100;
      error = None; cost_usd = 0.0001;
      execution_id = None;
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
      ~trace_id:"trace-007" ~generation:0 () in
    Trajectory.increment_turn acc;
    let mk tool = { Trajectory.
      ts = 1000.0; ts_iso = ""; turn = acc.Trajectory.turn; round = 0;
      tool_name = tool; args_json = "{}";
      gate_decision = Trajectory.Pass;
      result = Some "ok"; duration_ms = 10;
      error = None; cost_usd = 0.001;
      execution_id = None;
    } in
    Trajectory.record_entry acc (mk "tool_execute");
    Trajectory.record_entry acc (mk "tool_read_file");
    let count = Trajectory.calls_in_current_turn acc in
    Alcotest.(check int) "calls in turn 1" 2 count)

(* ================================================================ *)
(* Test: task_id binding and propagation                             *)
(* ================================================================ *)

let test_task_id_default_none () =
  with_tmpdir (fun dir ->
    let acc = Trajectory.create_accumulator
      ~masc_root:dir ~keeper_name:"test-keeper"
      ~trace_id:"trace-tid-001" ~generation:0 () in
    Alcotest.(check (option string)) "task_id default" None acc.Trajectory.task_id)

let test_set_task_id () =
  with_tmpdir (fun dir ->
    let acc = Trajectory.create_accumulator
      ~masc_root:dir ~keeper_name:"test-keeper"
      ~trace_id:"trace-tid-002" ~generation:0 () in
    Trajectory.set_task_id acc "task-042";
    Alcotest.(check (option string)) "task_id set"
      (Some "task-042") acc.Trajectory.task_id)

let test_clear_task_id () =
  with_tmpdir (fun dir ->
    let acc = Trajectory.create_accumulator
      ~masc_root:dir ~keeper_name:"test-keeper"
      ~trace_id:"trace-tid-003" ~generation:0 () in
    Trajectory.set_task_id acc "task-042";
    Trajectory.clear_task_id acc;
    Alcotest.(check (option string)) "task_id cleared" None acc.Trajectory.task_id)

let test_finalize_propagates_task_id () =
  with_tmpdir (fun dir ->
    let acc = Trajectory.create_accumulator
      ~masc_root:dir ~keeper_name:"test-keeper"
      ~trace_id:"trace-tid-004" ~generation:0 () in
    Trajectory.set_task_id acc "task-099";
    Trajectory.increment_turn acc;
    let traj = Trajectory.finalize acc Trajectory.Completed in
    Alcotest.(check (option string)) "task_id propagated"
      (Some "task-099") traj.Trajectory.task_id)

let test_task_id_in_trajectory_json () =
  with_tmpdir (fun dir ->
    let acc = Trajectory.create_accumulator
      ~masc_root:dir ~keeper_name:"test-keeper"
      ~trace_id:"trace-tid-005" ~generation:0 () in
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
      ~trace_id:"trace-tid-006" ~generation:0 () in
    let traj = Trajectory.finalize acc Trajectory.Completed in
    let json = Trajectory.trajectory_to_json traj in
    let open Yojson.Safe.Util in
    let task_id_val = json |> member "task_id" in
    match task_id_val with
    | `Null -> ()
    | _ -> Alcotest.fail "Expected task_id to be null when not set")

(* model_pricing tests removed — model_token_pricing / estimate_turn_cost
   deleted from Trajectory (#3029). Pricing belongs to OAS runtime. *)

(* ================================================================ *)
(* Test: aggregate_tool_stats                                        *)
(* ================================================================ *)

let mk_entry ?(ts = 1000.0) ?(error = None) ?(gate = Trajectory.Pass) name dur cost ts_iso =
  { Trajectory.
    ts; ts_iso; turn = 1; round = 0;
    tool_name = name; args_json = "{}";
    gate_decision = gate;
    result = Some "ok"; duration_ms = dur;
    error; cost_usd = cost;
    execution_id = None;
  }

let test_aggregate_basic () =
  let entries = [
    mk_entry "tool_execute" 100 0.001 "2026-04-06T10:00:00Z";
    mk_entry "tool_execute" 200 0.002 "2026-04-06T10:01:00Z";
    mk_entry "tool_execute" 300 0.001 "2026-04-06T10:02:00Z";
    mk_entry "tool_read_file" 50 0.0 "2026-04-06T10:03:00Z";
  ] in
  let stats = Trajectory.aggregate_tool_stats entries in
  Alcotest.(check int) "tool count" 2 (List.length stats);
  (* tool_execute has more calls, should be first *)
  let bash = List.hd stats in
  Alcotest.(check string) "first tool" "tool_execute" bash.Trajectory.name;
  Alcotest.(check int) "bash call count" 3 bash.Trajectory.call_count;
  Alcotest.(check int) "bash success count" 3 bash.Trajectory.success_count;
  Alcotest.(check int) "bash failure count" 0 bash.Trajectory.failure_count;
  Alcotest.(check int) "bash avg duration" 200 bash.Trajectory.avg_duration_ms;
  Alcotest.(check int) "bash max duration" 300 bash.Trajectory.max_duration_ms

let test_aggregate_with_errors () =
  let entries = [
    mk_entry "tool_execute" 100 0.001 "2026-04-06T10:00:00Z";
    mk_entry ~error:(Some "timeout") "tool_execute" 5000 0.001 "2026-04-06T10:01:00Z";
    mk_entry ~gate:(Trajectory.Reject "denied") "tool_execute" 0 0.0 "2026-04-06T10:02:00Z";
  ] in
  let stats = Trajectory.aggregate_tool_stats entries in
  Alcotest.(check int) "tool count" 1 (List.length stats);
  let s = List.hd stats in
  Alcotest.(check int) "call count" 3 s.Trajectory.call_count;
  Alcotest.(check int) "success" 1 s.Trajectory.success_count;
  Alcotest.(check int) "failure" 2 s.Trajectory.failure_count

let test_aggregate_empty () =
  let stats = Trajectory.aggregate_tool_stats [] in
  Alcotest.(check int) "empty" 0 (List.length stats)

let test_aggregate_p95 () =
  (* 20 entries: durations 100, 200, ..., 2000. p95 index = round(20 * 0.95) = 19 -> 2000 *)
  let entries = List.init 20 (fun i ->
    mk_entry "tool_execute" ((i + 1) * 100) 0.0
      (Printf.sprintf "2026-04-06T10:%02d:00Z" i)
  ) in
  let stats = Trajectory.aggregate_tool_stats entries in
  let s = List.hd stats in
  (* p95 of [100..2000] with 20 items — idx 19 = 2000 *)
  Alcotest.(check int) "p95" 2000 s.Trajectory.p95_duration_ms

(* ================================================================ *)
(* Test: hourly_timeline                                             *)
(* ================================================================ *)

let test_hourly_single_bucket () =
  let entries = [
    { (mk_entry "tool_execute" 100 0.0 "2026-04-06T10:05:00Z") with Trajectory.ts = 1743937500.0 };
    { (mk_entry "tool_execute" 100 0.0 "2026-04-06T10:30:00Z") with Trajectory.ts = 1743939000.0 };
  ] in
  let timeline = Trajectory.hourly_timeline entries in
  (* Both entries fall in the same hour bucket (25 min apart) *)
  Alcotest.(check int) "bucket count" 1 (List.length timeline);
  let b = List.hd timeline in
  Alcotest.(check int) "call count" 2 b.Trajectory.call_count;
  Alcotest.(check int) "error count" 0 b.Trajectory.error_count

let test_hourly_with_errors () =
  let entries = [
    { (mk_entry "tool_execute" 100 0.0 "2026-04-06T10:05:00Z") with Trajectory.ts = 1743937500.0 };
    { (mk_entry ~error:(Some "fail") "tool_execute" 100 0.0 "2026-04-06T10:30:00Z") with Trajectory.ts = 1743939000.0 };
  ] in
  let timeline = Trajectory.hourly_timeline entries in
  let b = List.hd timeline in
  Alcotest.(check int) "error count" 1 b.Trajectory.error_count

let test_hourly_empty () =
  let timeline = Trajectory.hourly_timeline [] in
  Alcotest.(check int) "empty" 0 (List.length timeline)

(* ================================================================ *)
(* Test: tool_stat_to_json / hourly_bucket_to_json                   *)
(* ================================================================ *)

let test_tool_stat_json_roundtrip () =
  let stat : Trajectory.tool_stat = {
    name = "tool_execute";
    call_count = 10;
    success_count = 9;
    failure_count = 1;
    avg_duration_ms = 150;
    p95_duration_ms = 500;
    max_duration_ms = 800;
    total_cost_usd = 0.01;
    last_used_at = "2026-04-06T12:00:00Z";
  } in
  let json = Trajectory.tool_stat_to_json stat in
  let open Yojson.Safe.Util in
  Alcotest.(check string) "name" "tool_execute" (json |> member "name" |> to_string);
  Alcotest.(check int) "call_count" 10 (json |> member "call_count" |> to_int);
  Alcotest.(check int) "p95" 500 (json |> member "p95_duration_ms" |> to_int);
  Alcotest.(check int) "failure" 1 (json |> member "failure_count" |> to_int)

let test_hourly_bucket_json () =
  let b : Trajectory.hourly_bucket = {
    hour = "2026-04-06T10:00:00Z";
    call_count = 5;
    error_count = 1;
  } in
  let json = Trajectory.hourly_bucket_to_json b in
  let open Yojson.Safe.Util in
  Alcotest.(check string) "hour" "2026-04-06T10:00:00Z" (json |> member "hour" |> to_string);
  Alcotest.(check int) "calls" 5 (json |> member "call_count" |> to_int);
  Alcotest.(check int) "errors" 1 (json |> member "error_count" |> to_int)

let test_entry_to_json_includes_contract_and_radius () =
  let entry : Trajectory.tool_call_entry = {
    ts = 1000.0;
    ts_iso = "2026-04-06T10:00:00Z";
    turn = 1;
    round = 1;
    tool_name = "tool_execute";
    args_json = {|{"command":"pwd"}|};
    gate_decision = Trajectory.Pass;
    result = Some "/tmp/work";
    duration_ms = 25;
    error = None;
    cost_usd = 0.0001;
    execution_id = Some "exec-1000-0001";
  } in
  let runtime_contract =
    Keeper_runtime_contract.runtime_observability_contract_json_from_fields
      ~keeper_name:"alpha"
      ~agent_name:"alpha-agent"
      ~trace_id:"trace-alpha"
      ~generation:2
      ~sandbox_profile:"docker"
      ()
  in
  let action_radius =
    Keeper_runtime_contract.action_radius_json
      ~tool_name:"tool_execute"
      ~input:(`Assoc [("cwd", `String "/tmp/work")])
      ~success:true
      ~duration_ms:25.0
      ()
  in
  let json =
    Trajectory.entry_to_json ~runtime_contract ~action_radius entry
  in
  let open Yojson.Safe.Util in
  Alcotest.(check string) "runtime keeper" "alpha"
    (json |> member "runtime_contract" |> member "keeper_name" |> to_string);
  Alcotest.(check string) "action tool" "tool_execute"
    (json |> member "action_radius" |> member "tool_name" |> to_string);
  Alcotest.(check string) "observed path" "/tmp/work"
    (json |> member "action_radius" |> member "observed_paths" |> to_list
     |> List.hd |> to_string);
  Alcotest.(check string) "execution_id persisted" "exec-1000-0001"
    (json |> member "execution_id" |> to_string)

(* RFC-0233 PR-1: the canonical join key survives the JSONL round-trip,
   and rows written before the field existed decode as [None]. *)
let test_execution_id_roundtrip () =
  let entry : Trajectory.tool_call_entry = {
    ts = 1000.0; ts_iso = "2026-06-12T00:00:00Z"; turn = 3; round = 1;
    tool_name = "tool_execute"; args_json = "{}";
    gate_decision = Trajectory.Pass;
    result = Some "ok"; duration_ms = 10; error = None; cost_usd = 0.0;
    execution_id = Some "exec-1718150400000-0001";
  } in
  (match Trajectory.tool_call_entry_of_json (Trajectory.entry_to_json entry) with
   | Some (decoded, _) ->
       Alcotest.(check (option string)) "round-trip"
         (Some "exec-1718150400000-0001") decoded.Trajectory.execution_id
   | None -> Alcotest.fail "entry did not decode");
  let legacy = Trajectory.entry_to_json { entry with execution_id = None } in
  match Trajectory.tool_call_entry_of_json legacy with
  | Some (decoded, _) ->
      Alcotest.(check (option string)) "legacy row decodes as None" None
        decoded.Trajectory.execution_id
  | None -> Alcotest.fail "legacy entry did not decode"

let has_assoc_key key = function
  | `Assoc fields -> List.mem_assoc key fields
  | _ -> false

let test_runtime_contract_projection_redacts_backend_details () =
  let keeper_visible =
    Keeper_runtime_contract.runtime_contract_json_from_fields
      ~keeper_name:"alpha"
      ~agent_name:"alpha-agent"
      ~trace_id:"trace-alpha"
      ~generation:2
      ~sandbox_profile:"docker"
      ~sandbox_root:"/workspace"
      ~network_mode:"none"
      ()
  in
  let observability =
    Keeper_runtime_contract.runtime_observability_contract_json_from_fields
      ~keeper_name:"alpha"
      ~agent_name:"alpha-agent"
      ~trace_id:"trace-alpha"
      ~generation:2
      ~sandbox_profile:"docker"
      ~sandbox_root:"/workspace"
      ~network_mode:"none"
      ()
  in
  let open Yojson.Safe.Util in
  Alcotest.(check bool) "keeper contract redacts sandbox_profile" false
    (has_assoc_key "sandbox_profile" keeper_visible);
  Alcotest.(check bool) "keeper contract redacts network_mode" false
    (has_assoc_key "network_mode" keeper_visible);
  Alcotest.(check string) "keeper contract keeps sandbox root" "/workspace"
    (keeper_visible |> member "sandbox_root" |> to_string);
  Alcotest.(check bool) "keeper contract says Read has no implicit cwd" false
    (keeper_visible |> member "path_resolution" |> member "read_implicit_cwd"
     |> to_bool);
  Alcotest.(check string) "observability keeps sandbox_profile" "docker"
    (observability |> member "sandbox_profile" |> to_string);
  Alcotest.(check string) "observability keeps network_mode" "none"
    (observability |> member "network_mode" |> to_string)

(* ================================================================ *)
(* Test: read_entries_since (file-based)                             *)
(* ================================================================ *)

let test_read_entries_since () =
  with_tmpdir (fun dir ->
    let masc_root = dir in
    let keeper = "test-keeper" in
    (* Create a trajectory file manually *)
    let traj_dir = Filename.concat masc_root (Printf.sprintf "trajectories/%s" keeper) in
    Fs_compat.mkdir_p traj_dir;
    let path = Filename.concat traj_dir "trace-100.jsonl" in
    let entry_json ts = Printf.sprintf
      {|{"ts":%.1f,"ts_iso":"2026-04-06T10:00:00Z","turn":1,"round":0,"tool_name":"tool_execute","args":{},"result":"ok","duration_ms":100,"error":null,"cost_usd":0.001}|}
      ts
    in
    let oc = open_out path in
    Printf.fprintf oc "%s\n" (entry_json 1000.0);
    Printf.fprintf oc "%s\n" (entry_json 2000.0);
    Printf.fprintf oc "%s\n" (entry_json 3000.0);
    close_out oc;
    (* Read since ts=1500 should get 2 entries *)
    let entries = Trajectory.read_entries_since ~masc_root ~keeper_name:keeper ~since:1500.0 in
    Alcotest.(check int) "entries since 1500" 2 (List.length entries);
    (* Read since ts=0 should get all 3 *)
    let all = Trajectory.read_entries_since ~masc_root ~keeper_name:keeper ~since:0.0 in
    Alcotest.(check int) "all entries" 3 (List.length all))

let test_read_entries_since_result_parses_gate_summary () =
  with_tmpdir (fun dir ->
    let masc_root = dir in
    let keeper = "test-keeper" in
    let traj_dir = Filename.concat masc_root (Printf.sprintf "trajectories/%s" keeper) in
    Fs_compat.mkdir_p traj_dir;
    let path = Filename.concat traj_dir "trace-101.jsonl" in
    let rows =
      [
        {|{"ts":1000.0,"ts_iso":"2026-04-06T10:00:00Z","turn":1,"round":1,"tool_name":"tool_execute","args":{},"gate":{"status":"pass"},"result":"ok","duration_ms":100,"error":null,"cost_usd":0.001}|};
        {|{"ts":2000.0,"ts_iso":"2026-04-06T10:01:00Z","turn":1,"round":2,"tool_name":"tool_execute","args":{},"gate":{"status":"reject","reason":"blocked"},"result":null,"duration_ms":0,"error":"blocked","cost_usd":0.0}|};
        {|{"ts":3000.0,"ts_iso":"2026-04-06T10:02:00Z","turn":1,"round":3,"tool_name":"tool_execute","args":{},"result":"legacy","duration_ms":10,"error":null,"cost_usd":0.001}|};
      ]
    in
    let oc = open_out path in
    List.iter (Printf.fprintf oc "%s\n") rows;
    close_out oc;
    let result =
      Trajectory.read_entries_since_result ~masc_root ~keeper_name:keeper
        ~since:0.0
    in
    Alcotest.(check int) "three entries" 3 (List.length result.Trajectory.entries);
    Alcotest.(check int) "parsed gate count" 2
      result.Trajectory.gate_decode.parsed_gate_count;
    Alcotest.(check int) "legacy default count" 1
      result.Trajectory.gate_decode.legacy_default_count;
    match List.nth result.Trajectory.entries 1 with
    | { Trajectory.gate_decision = Trajectory.Reject reason; _ } ->
      Alcotest.(check string) "reject reason parsed" "blocked" reason
    | _ -> Alcotest.fail "expected persisted reject gate")

let test_read_entries_since_no_dir () =
  with_tmpdir (fun dir ->
    let entries = Trajectory.read_entries_since ~masc_root:dir ~keeper_name:"nonexistent" ~since:0.0 in
    Alcotest.(check int) "no dir" 0 (List.length entries))

let thinking_line ?(ts = 1000.0) ?(redacted = false) content =
  Trajectory.Thinking
    {
      ts;
      ts_iso = "2026-06-29T00:00:00Z";
      turn = 1;
      content;
      content_length = String.length content;
      redacted;
    }

let check_thinking_content label expected = function
  | Trajectory.Thinking entry ->
      Alcotest.(check string) label expected entry.Trajectory.content
  | Trajectory.Tool_call _ -> Alcotest.fail (label ^ ": expected thinking line")

let check_tool_call label expected = function
  | Trajectory.Tool_call entry ->
      Alcotest.(check string) label expected entry.Trajectory.tool_name
  | Trajectory.Thinking _ -> Alcotest.fail (label ^ ": expected tool call line")

let test_dedupe_thinking_lines_uses_structural_key () =
  let tool_call =
    Trajectory.Tool_call
      (mk_entry ~ts:1000.5 "tool_execute" 20 0.0 "2026-06-29T00:00:00Z")
  in
  let lines =
    [
      thinking_line ~ts:1000.0 "same";
      tool_call;
      thinking_line ~ts:1000.0 "same";
      thinking_line ~ts:1001.0 "same";
      thinking_line ~ts:1000.0 ~redacted:true "same";
    ]
  in
  let deduped =
    Server_dashboard_http_keeper_api_trace.dedupe_thinking_lines lines
  in
  Alcotest.(check int) "one exact duplicate removed" 4 (List.length deduped);
  check_thinking_content "first thinking preserved" "same" (List.nth deduped 0);
  check_tool_call "tool call preserved" "tool_execute" (List.nth deduped 1);
  check_thinking_content "same content at a new timestamp preserved" "same"
    (List.nth deduped 2);
  (match List.nth deduped 3 with
   | Trajectory.Thinking entry ->
       Alcotest.(check bool) "redacted variant preserved" true entry.Trajectory.redacted
   | Trajectory.Tool_call _ -> Alcotest.fail "expected redacted thinking line")

(* ================================================================ *)
(* Runner                                                            *)
(* ================================================================ *)

(* ================================================================ *)
(* Test: thinking trajectory — full untruncated text, per-turn        *)
(* ================================================================ *)

let read_thinking_jsonl ~masc_root ~keeper_name ~trace_id =
  let path = Filename.concat masc_root
    (Printf.sprintf "trajectories/%s/%s.jsonl" keeper_name trace_id) in
  if not (Sys.file_exists path) then []
  else begin
    let ic = open_in path in
    Fun.protect ~finally:(fun () -> close_in_noerr ic) (fun () ->
      let rec loop acc =
        match input_line ic with
        | line -> loop (Yojson.Safe.from_string line :: acc)
        | exception End_of_file -> List.rev acc
      in
      loop [])
  end

(* append_thinking must persist the FULL text, not the legacy 2000-byte cap. *)
let test_append_thinking_persists_untruncated () =
  with_tmpdir (fun dir ->
    let big = String.make 9000 'x' in
    let entry : Trajectory.thinking_entry = {
      ts = 1000.0; ts_iso = "2026-06-09T00:00:00Z"; turn = 4;
      content = big; content_length = String.length big; redacted = false;
    } in
    Trajectory.append_thinking ~masc_root:dir ~keeper_name:"k" ~trace_id:"th1" entry;
    let lines = read_thinking_jsonl ~masc_root:dir ~keeper_name:"k" ~trace_id:"th1" in
    Alcotest.(check int) "one thinking line" 1 (List.length lines);
    let open Yojson.Safe.Util in
    let row = List.hd lines in
    Alcotest.(check string) "type=thinking" "thinking" (row |> member "type" |> to_string);
    Alcotest.(check int) "content untruncated (9000B, not 2000 cap)" 9000
      (row |> member "content" |> to_string |> String.length);
    Alcotest.(check int) "content_length records true length" 9000
      (row |> member "content_length" |> to_int))

(* persist_response_content stamps every block with the hook's ~turn (not
   acc.turn) and writes one line per thinking block, untruncated. *)
let test_persist_response_content_per_turn_full () =
  with_tmpdir (fun dir ->
    let acc = Trajectory.create_accumulator
      ~masc_root:dir ~keeper_name:"k" ~trace_id:"th2" ~generation:0 () in
    (* acc.turn stays 0; the hook passes ~turn:11 — assert ~turn wins. *)
    let big = String.make 5000 'a' in
    let content = [
      Agent_sdk.Types.Thinking { signature = None; content = big };
      Agent_sdk.Types.Thinking { signature = None; content = "second block" };
    ] in
    Keeper_agent_run_thinking_trajectory.persist_response_content
      ~keeper_name:"k" ~trajectory_acc:(Some acc) ~turn:11 content;
    let lines = read_thinking_jsonl ~masc_root:dir ~keeper_name:"k" ~trace_id:"th2" in
    let open Yojson.Safe.Util in
    Alcotest.(check int) "both thinking blocks persisted" 2 (List.length lines);
    List.iter (fun row ->
      Alcotest.(check int) "turn stamped from hook (11), not acc.turn (0)" 11
        (row |> member "turn" |> to_int)) lines;
    Alcotest.(check int) "first block untruncated (5000B)" 5000
      (List.hd lines |> member "content" |> to_string |> String.length))

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
    ("aggregate_tool_stats", [
      Alcotest.test_case "basic aggregation" `Quick test_aggregate_basic;
      Alcotest.test_case "with errors and rejected gates" `Quick test_aggregate_with_errors;
      Alcotest.test_case "empty input" `Quick test_aggregate_empty;
      Alcotest.test_case "p95 calculation" `Quick test_aggregate_p95;
    ]);
    ("hourly_timeline", [
      Alcotest.test_case "single bucket" `Quick test_hourly_single_bucket;
      Alcotest.test_case "with errors" `Quick test_hourly_with_errors;
      Alcotest.test_case "empty input" `Quick test_hourly_empty;
    ]);
    ("json_serialization", [
      Alcotest.test_case "tool_stat to json" `Quick test_tool_stat_json_roundtrip;
      Alcotest.test_case "hourly_bucket to json" `Quick test_hourly_bucket_json;
      Alcotest.test_case "entry carries runtime/action telemetry" `Quick
        test_entry_to_json_includes_contract_and_radius;
      Alcotest.test_case "execution_id JSONL round-trip + legacy None" `Quick
        test_execution_id_roundtrip;
      Alcotest.test_case "runtime contract redacts backend details" `Quick
        test_runtime_contract_projection_redacts_backend_details;
    ]);
    ("read_entries_since", [
      Alcotest.test_case "filter by timestamp" `Quick test_read_entries_since;
      Alcotest.test_case "parses persisted gate summary" `Quick
        test_read_entries_since_result_parses_gate_summary;
      Alcotest.test_case "nonexistent directory" `Quick test_read_entries_since_no_dir;
    ]);
    ("keeper_trace", [
      Alcotest.test_case "dedupe_thinking_lines uses structural key" `Quick
        test_dedupe_thinking_lines_uses_structural_key;
    ]);
    ("thinking_trajectory", [
      Alcotest.test_case "append_thinking persists full untruncated text" `Quick
        test_append_thinking_persists_untruncated;
      Alcotest.test_case "persist_response_content stamps hook turn, all blocks" `Quick
        test_persist_response_content_per_turn_full;
    ]);
  ]
