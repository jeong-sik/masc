(** Tests for OAS v0.68.0 module integration.

    Phase 1: Cost_tracker bridge
    Phase 2: Context_offload fail-open
    Phase 3: Eval_baseline + Eval_report bridge

    All tests are pure — no LLM or external calls. *)

open Alcotest

(* ================================================================ *)
(* Phase 1: Cost_tracker bridge via Eval_gate                        *)
(* ================================================================ *)

let test_cost_report_basic () =
  let cr = Masc_mcp.Eval_gate.cost_report
    ~accumulated_cost:0.25
    ~api_calls:10
    ~input_tokens:5000
    ~output_tokens:2000
  in
  check (float 0.001) "total_usd" 0.25 cr.Agent_sdk.Cost_tracker.total_usd;
  check int "api_calls" 10 cr.api_calls;
  check int "input_tokens" 5000 cr.input_tokens;
  check int "output_tokens" 2000 cr.output_tokens;
  check (float 0.001) "avg_cost_per_call" 0.025 cr.avg_cost_per_call

let test_cost_report_zero () =
  let cr = Masc_mcp.Eval_gate.cost_report
    ~accumulated_cost:0.0
    ~api_calls:0
    ~input_tokens:0
    ~output_tokens:0
  in
  check (float 0.001) "total zero" 0.0 cr.Agent_sdk.Cost_tracker.total_usd;
  check (float 0.001) "avg zero" 0.0 cr.avg_cost_per_call

let test_cost_report_to_string () =
  let cr = Masc_mcp.Eval_gate.cost_report
    ~accumulated_cost:0.123456
    ~api_calls:5
    ~input_tokens:1000
    ~output_tokens:500
  in
  let s = Masc_mcp.Eval_gate.cost_report_to_string cr in
  check bool "contains cost" true (String.length s > 0);
  check bool "contains dollar" true
    (try ignore (Str.search_forward (Str.regexp_string "0.123456") s 0); true
     with Not_found -> false)

(* ================================================================ *)
(* Phase 2: Context_offload                                          *)
(* ================================================================ *)

let test_offload_small_content () =
  let config : Agent_sdk.Context_offload.config = {
    threshold_bytes = 100;
    output_dir = Filename.get_temp_dir_name ();
    preview_len = 50;
  } in
  let small = "hello world" in
  let result = Agent_sdk.Context_offload.offload_tool_result
    ~config ~tool_name:"test_tool" small in
  check string "small kept as-is" small result

let test_offload_large_content () =
  let config : Agent_sdk.Context_offload.config = {
    threshold_bytes = 50;
    output_dir = Filename.get_temp_dir_name ();
    preview_len = 20;
  } in
  let large = String.make 200 'x' in
  let result = Agent_sdk.Context_offload.offload_tool_result
    ~config ~tool_name:"test_tool" large in
  check bool "result contains Offloaded marker" true
    (try ignore (Str.search_forward (Str.regexp_string "Offloaded") result 0); true
     with Not_found -> false);
  check bool "result contains preview" true
    (try ignore (Str.search_forward (Str.regexp_string "xxx") result 0); true
     with Not_found -> false);
  check bool "result contains byte count" true
    (try ignore (Str.search_forward (Str.regexp_string "200 bytes") result 0); true
     with Not_found -> false)

let test_offload_fail_open () =
  let config : Agent_sdk.Context_offload.config = {
    threshold_bytes = 10;
    output_dir = "/nonexistent/path/that/should/fail";
    preview_len = 5;
  } in
  let content = String.make 50 'y' in
  let result = Agent_sdk.Context_offload.offload_tool_result
    ~config ~tool_name:"fail_test" content in
  (* Fail-open: returns original content when write fails *)
  check string "fail-open returns original" content result

(* ================================================================ *)
(* Phase 3: Eval_baseline bridge                                     *)
(* ================================================================ *)

let test_eval_baseline_save_load () =
  let tmp = Filename.temp_file "oas_baseline_" ".json" in
  let scenario : Masc_mcp.Eval_harness.scenario = {
    id = "test-scenario-1";
    name = "Test Scenario";
    description = "For testing baseline bridge";
    category = "test";
    goal = "pass the test";
    setup_messages = [];
    expected_outcome = "should pass";
    tool_expectations = [];
    graders = [];
    max_turns = 5;
    max_cost_usd = 0.10;
    tags = ["unit-test"];
  } in
  let run : Masc_mcp.Eval_harness.eval_run = {
    scenario_id = "test-scenario-1";
    run_index = 0;
    trace_id = "trace-001";
    scores = [];
    weighted_score = 0.85;
    passed = true;
    tool_calls_made = ["keeper_read"];
    total_turns = 3;
    total_cost_usd = 0.05;
    duration_ms = 1200;
    outcome = Masc_mcp.Trajectory.Completed;
    error = None;
  } in
  let eval_result : Masc_mcp.Eval_harness.eval_result = {
    scenario;
    runs = [run];
    pass_at_k = 1.0;
    mean_score = 0.85;
    consistency = 0.0;
    total_cost_usd = 0.05;
  } in
  let suite : Masc_mcp.Eval_harness.eval_suite_result = {
    suite_name = "test-suite";
    started_at = 0.0;
    ended_at = 1.0;
    results = [eval_result];
    overall_pass_rate = 1.0;
    total_cost_usd = 0.05;
    total_runs = 1;
  } in
  (* Save baseline *)
  (match Masc_mcp.Eval_harness.save_oas_baseline ~path:tmp ~description:"test baseline" suite with
   | Ok () -> ()
   | Error e -> fail (Printf.sprintf "save failed: %s" e));
  (* Load and compare *)
  (match Masc_mcp.Eval_harness.compare_oas_baseline ~baseline_path:tmp eval_result with
   | Error e -> fail (Printf.sprintf "compare failed: %s" e)
   | Ok comparison ->
     check bool "no regressions" true comparison.Agent_sdk.Eval_baseline.passed;
     check int "zero regressions" 0 comparison.regressions);
  Sys.remove tmp

let test_eval_report_generation () =
  let scenario : Masc_mcp.Eval_harness.scenario = {
    id = "report-test";
    name = "Report Test";
    description = "Test OAS report generation";
    category = "test";
    goal = "generate report";
    setup_messages = [];
    expected_outcome = "report generated";
    tool_expectations = [];
    graders = [];
    max_turns = 3;
    max_cost_usd = 0.10;
    tags = [];
  } in
  let run : Masc_mcp.Eval_harness.eval_run = {
    scenario_id = "report-test";
    run_index = 0;
    trace_id = "trace-r1";
    scores = [];
    weighted_score = 0.90;
    passed = true;
    tool_calls_made = [];
    total_turns = 2;
    total_cost_usd = 0.03;
    duration_ms = 800;
    outcome = Masc_mcp.Trajectory.Completed;
    error = None;
  } in
  let eval_result : Masc_mcp.Eval_harness.eval_result = {
    scenario;
    runs = [run];
    pass_at_k = 1.0;
    mean_score = 0.90;
    consistency = 0.0;
    total_cost_usd = 0.03;
  } in
  let report = Masc_mcp.Eval_harness.generate_oas_report eval_result in
  check string "agent name" "Report Test" report.Agent_sdk.Eval_report.agent_name;
  check int "run count" 1 report.run_count;
  let report_str = Agent_sdk.Eval_report.to_string report in
  check bool "report not empty" true (String.length report_str > 0)

(* ================================================================ *)
(* Runner                                                            *)
(* ================================================================ *)

let () =
  run "OAS v0.68.0 integration" [
    "cost_tracker", [
      test_case "basic report" `Quick test_cost_report_basic;
      test_case "zero values" `Quick test_cost_report_zero;
      test_case "report to string" `Quick test_cost_report_to_string;
    ];
    "context_offload", [
      test_case "small content kept" `Quick test_offload_small_content;
      test_case "large content offloaded" `Quick test_offload_large_content;
      test_case "fail-open on write error" `Quick test_offload_fail_open;
    ];
    "eval_baseline", [
      test_case "save and compare baseline" `Quick test_eval_baseline_save_load;
      test_case "report generation" `Quick test_eval_report_generation;
    ];
  ]
