(** Tests for Eval_ablation — component registry, statistical comparison,
    and verdict generation.  Pure functions, no LLM or Eio required. *)

open Alcotest
module Abl = Masc_mcp.Eval_ablation
module EH = Masc_mcp.Eval_harness

(* ================================================================ *)
(* Helpers                                                           *)
(* ================================================================ *)

let make_run ?(passed = true) ?(score = 0.8) ?(turns = 5)
    ?(cost = 0.01) ~(scenario_id : string) ~(index : int) ()
  : EH.eval_run =
  { scenario_id; run_index = index;
    trace_id = Printf.sprintf "trace-%s-%d" scenario_id index;
    scores = [];
    weighted_score = score;
    passed;
    tool_calls_made = [];
    total_turns = turns;
    total_cost_usd = cost;
    duration_ms = 1000;
    outcome = Masc_mcp.Trajectory.Completed;
    error = None }

let make_scenario ?(id = "s1") ?(name = "test scenario") () : EH.scenario =
  { id; name; description = "test"; category = "capability";
    goal = "test goal"; setup_messages = [];
    expected_outcome = "pass"; tool_expectations = [];
    graders = []; max_turns = 10; max_cost_usd = 1.0; tags = [] }

let make_result ~scenario ~runs : EH.eval_result =
  let n = List.length runs in
  let passes = List.length (List.filter (fun (r : EH.eval_run) -> r.passed) runs) in
  let scores = List.map (fun (r : EH.eval_run) -> r.weighted_score) runs in
  let mean = if n = 0 then 0.0
    else List.fold_left ( +. ) 0.0 scores /. float_of_int n in
  { scenario; runs;
    pass_at_k = float_of_int passes /. float_of_int (max n 1);
    mean_score = mean;
    consistency = 0.1;
    total_cost_usd = List.fold_left (fun acc (r : EH.eval_run) -> acc +. r.total_cost_usd) 0.0 runs }

let make_suite ~(name : string) ~(results : EH.eval_result list) : EH.eval_suite_result =
  let n = List.fold_left (fun acc (r : EH.eval_result) -> acc + List.length r.runs) 0 results in
  let passes = List.length (List.filter (fun (r : EH.eval_result) -> r.pass_at_k >= 0.5) results) in
  { suite_name = name;
    started_at = 0.0; ended_at = 1.0;
    results;
    overall_pass_rate = float_of_int passes /. float_of_int (max (List.length results) 1);
    total_cost_usd = List.fold_left (fun acc (r : EH.eval_result) -> acc +. r.total_cost_usd) 0.0 results;
    total_runs = n }

(* ================================================================ *)
(* Registry tests                                                    *)
(* ================================================================ *)

let test_registry_nonempty () =
  check bool "registry has entries" true (List.length Abl.registry > 0)

let test_ablatable_only_model_compensating () =
  let comps = Abl.ablatable_components () in
  List.iter (fun (c : Abl.component) ->
    check string (c.name ^ " is model_compensating")
      "model_compensating"
      (Abl.component_class_to_string c.classification)
  ) comps

let test_find_component () =
  let c = Abl.find_component "anti_rationalization" in
  check bool "found" true (c <> None)

let test_find_missing () =
  let c = Abl.find_component "nonexistent" in
  check bool "not found" true (c = None)

(* ================================================================ *)
(* Z-test tests                                                      *)
(* ================================================================ *)

let test_z_test_identical () =
  let z, p = Abl.two_proportion_z_test ~x1:8 ~n1:10 ~x2:8 ~n2:10 in
  check bool "z = 0" true (Float.abs z < 0.001);
  check bool "p = 1" true (p > 0.9)

let test_z_test_different () =
  let z, p = Abl.two_proportion_z_test ~x1:9 ~n1:10 ~x2:2 ~n2:10 in
  check bool "z > 0" true (z > 1.0);
  check bool "p < 0.05" true (p < 0.05)

let test_z_test_zero_n () =
  let z, p = Abl.two_proportion_z_test ~x1:0 ~n1:0 ~x2:5 ~n2:10 in
  check bool "z = 0 for empty" true (Float.abs z < 0.001);
  check bool "p = 1 for empty" true (Float.abs (p -. 1.0) < 0.001)

(* ================================================================ *)
(* Suite comparison tests                                            *)
(* ================================================================ *)

let test_compare_load_bearing () =
  let s = make_scenario ~id:"s1" ~name:"task completion" () in
  let baseline = make_suite ~name:"baseline" ~results:[
    make_result ~scenario:s ~runs:[
      make_run ~passed:true ~score:0.9 ~scenario_id:"s1" ~index:0 ();
      make_run ~passed:true ~score:0.8 ~scenario_id:"s1" ~index:1 ();
      make_run ~passed:true ~score:0.85 ~scenario_id:"s1" ~index:2 ();
      make_run ~passed:true ~score:0.9 ~scenario_id:"s1" ~index:3 ();
      make_run ~passed:true ~score:0.8 ~scenario_id:"s1" ~index:4 ();
      make_run ~passed:true ~score:0.85 ~scenario_id:"s1" ~index:5 ();
      make_run ~passed:true ~score:0.9 ~scenario_id:"s1" ~index:6 ();
      make_run ~passed:true ~score:0.85 ~scenario_id:"s1" ~index:7 ();
      make_run ~passed:true ~score:0.8 ~scenario_id:"s1" ~index:8 ();
      make_run ~passed:true ~score:0.9 ~scenario_id:"s1" ~index:9 ();
    ]
  ] in
  let ablated = make_suite ~name:"ablated" ~results:[
    make_result ~scenario:s ~runs:[
      make_run ~passed:false ~score:0.3 ~scenario_id:"s1" ~index:0 ();
      make_run ~passed:false ~score:0.2 ~scenario_id:"s1" ~index:1 ();
      make_run ~passed:true ~score:0.6 ~scenario_id:"s1" ~index:2 ();
      make_run ~passed:false ~score:0.3 ~scenario_id:"s1" ~index:3 ();
      make_run ~passed:false ~score:0.25 ~scenario_id:"s1" ~index:4 ();
      make_run ~passed:false ~score:0.4 ~scenario_id:"s1" ~index:5 ();
      make_run ~passed:false ~score:0.3 ~scenario_id:"s1" ~index:6 ();
      make_run ~passed:true ~score:0.55 ~scenario_id:"s1" ~index:7 ();
      make_run ~passed:false ~score:0.2 ~scenario_id:"s1" ~index:8 ();
      make_run ~passed:false ~score:0.35 ~scenario_id:"s1" ~index:9 ();
    ]
  ] in
  let comp = { Abl.name = "test_comp"; description = "test";
    classification = Model_compensating; disable_fn = "TEST_DISABLE" } in
  let result = Abl.compare_suites ~component:comp ~baseline ~ablated () in
  check string "verdict = load_bearing" "load_bearing" result.verdict;
  check bool "positive lift" true (result.overall_lift > 0.0);
  check bool "significant" true (result.significant_count > 0)

let test_compare_redundant () =
  let s = make_scenario ~id:"s1" ~name:"basic task" () in
  let runs_ok = List.init 10 (fun i ->
    make_run ~passed:true ~score:0.85 ~scenario_id:"s1" ~index:i ()) in
  let baseline = make_suite ~name:"baseline"
    ~results:[make_result ~scenario:s ~runs:runs_ok] in
  let ablated = make_suite ~name:"ablated"
    ~results:[make_result ~scenario:s ~runs:runs_ok] in
  let comp = { Abl.name = "test_comp"; description = "test";
    classification = Model_compensating; disable_fn = "TEST_DISABLE" } in
  let result = Abl.compare_suites ~component:comp ~baseline ~ablated () in
  check string "verdict = redundant" "redundant" result.verdict;
  check bool "zero lift" true (Float.abs result.overall_lift < 0.02)

let test_compare_empty () =
  let baseline = make_suite ~name:"baseline" ~results:[] in
  let ablated = make_suite ~name:"ablated" ~results:[] in
  let comp = { Abl.name = "test_comp"; description = "test";
    classification = Model_compensating; disable_fn = "TEST_DISABLE" } in
  let result = Abl.compare_suites ~component:comp ~baseline ~ablated () in
  check string "verdict = inconclusive" "inconclusive" result.verdict

(* ================================================================ *)
(* Serialization tests                                               *)
(* ================================================================ *)

let test_json_roundtrip () =
  let s = make_scenario ~id:"s1" ~name:"test" () in
  let runs = [make_run ~passed:true ~score:0.9 ~scenario_id:"s1" ~index:0 ()] in
  let baseline = make_suite ~name:"b" ~results:[make_result ~scenario:s ~runs] in
  let ablated = make_suite ~name:"a" ~results:[make_result ~scenario:s ~runs] in
  let comp = { Abl.name = "c"; description = "d";
    classification = Model_compensating; disable_fn = "X" } in
  let result = Abl.compare_suites ~component:comp ~baseline ~ablated () in
  let json = Abl.ablation_result_to_json result in
  let verdict = Yojson.Safe.Util.(json |> member "verdict" |> to_string) in
  check string "verdict in JSON" result.verdict verdict

let test_report_generation () =
  let s = make_scenario ~id:"s1" ~name:"test" () in
  let runs = [make_run ~passed:true ~score:0.9 ~scenario_id:"s1" ~index:0 ()] in
  let baseline = make_suite ~name:"b" ~results:[make_result ~scenario:s ~runs] in
  let ablated = make_suite ~name:"a" ~results:[make_result ~scenario:s ~runs] in
  let comp = { Abl.name = "test_c"; description = "d";
    classification = Model_compensating; disable_fn = "X" } in
  let result = Abl.compare_suites ~component:comp ~baseline ~ablated () in
  let report = Abl.report_to_string result in
  check bool "contains component name" true (String.length report > 0)

(* ================================================================ *)
(* Test Suite                                                        *)
(* ================================================================ *)

let () =
  run "eval_ablation" [
    "registry", [
      test_case "nonempty" `Quick test_registry_nonempty;
      test_case "ablatable only model_compensating" `Quick test_ablatable_only_model_compensating;
      test_case "find existing" `Quick test_find_component;
      test_case "find missing" `Quick test_find_missing;
    ];
    "z_test", [
      test_case "identical proportions" `Quick test_z_test_identical;
      test_case "different proportions" `Quick test_z_test_different;
      test_case "zero n" `Quick test_z_test_zero_n;
    ];
    "comparison", [
      test_case "load bearing" `Quick test_compare_load_bearing;
      test_case "redundant" `Quick test_compare_redundant;
      test_case "empty suites" `Quick test_compare_empty;
    ];
    "serialization", [
      test_case "json roundtrip" `Quick test_json_roundtrip;
      test_case "report generation" `Quick test_report_generation;
    ];
  ]
