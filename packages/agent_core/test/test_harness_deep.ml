(** Deep tests for Harness module — targeting uncovered branches.

    Covers: Adversarial.ErrorContains, Performance edge cases,
    Regression.StructuralMatch / FuzzyMatch boundary, Swiss_cheese
    empty layers, Composability.AllAgentsCompleted, Behavioral score
    aggregation, and verdict detail messages. *)

open Agent_sdk

(* ── Adversarial: ErrorContains ────────────────────────────── *)

let test_adversarial_error_contains_found () =
  let obs : Harness.Adversarial.observation =
    { result = Error (Error.Internal "timeout exceeded")
    ; tools_executed = []
    ; error_message = Some "timeout exceeded while waiting"
    }
  in
  let v = Harness.Adversarial.evaluate obs (ErrorContains "timeout") in
  Alcotest.(check bool) "needle found in error" true v.passed;
  Alcotest.(check bool) "evidence non-empty" true (v.evidence <> [])
;;

let test_adversarial_error_contains_not_found () =
  let obs : Harness.Adversarial.observation =
    { result = Error (Error.Internal "connection reset")
    ; tools_executed = []
    ; error_message = Some "connection reset"
    }
  in
  let v = Harness.Adversarial.evaluate obs (ErrorContains "timeout") in
  Alcotest.(check bool) "needle not in error" false v.passed;
  Alcotest.(check bool) "detail present" true (Option.is_some v.detail)
;;

let test_adversarial_error_contains_none () =
  let obs : Harness.Adversarial.observation =
    { result =
        Ok
          { id = "ok"
          ; model = "m"
          ; stop_reason = Types.EndTurn
          ; content = [ Types.Text "fine" ]
          ; usage = None
          ; telemetry = None
          }
    ; tools_executed = []
    ; error_message = None
    }
  in
  let v = Harness.Adversarial.evaluate obs (ErrorContains "anything") in
  Alcotest.(check bool) "no error message -> fail" false v.passed
;;

let test_adversarial_graceful_error_ok_result () =
  let obs : Harness.Adversarial.observation =
    { result =
        Ok
          { id = "ok"
          ; model = "m"
          ; stop_reason = Types.EndTurn
          ; content = [ Types.Text "ok" ]
          ; usage = None
          ; telemetry = None
          }
    ; tools_executed = []
    ; error_message = None
    }
  in
  let v = Harness.Adversarial.evaluate obs GracefulError in
  Alcotest.(check bool) "ok result -> graceful error fails" false v.passed;
  Alcotest.(check bool)
    "detail says expected error"
    true
    (match v.detail with
     | Some d -> Util.string_contains ~needle:"Expected error" d
     | None -> false)
;;

let test_adversarial_no_tool_with_tools () =
  let obs : Harness.Adversarial.observation =
    { result = Error (Error.Internal "err")
    ; tools_executed = [ "rm_rf"; "drop_table" ]
    ; error_message = Some "err"
    }
  in
  let v = Harness.Adversarial.evaluate obs NoToolExecution in
  Alcotest.(check bool) "tools executed -> fail" false v.passed;
  Alcotest.(check bool)
    "detail lists tools"
    true
    (match v.detail with
     | Some d -> Util.string_contains ~needle:"rm_rf" d
     | None -> false)
;;

(* ── Performance: edge cases ──────────────────────────────── *)

let test_performance_p95_empty () =
  let p = Harness.Performance.p95 [] in
  Alcotest.(check (float 0.001)) "p95 of empty = 0.0" 0.0 p
;;

let test_performance_p95_single () =
  let p = Harness.Performance.p95 [ 42.0 ] in
  Alcotest.(check (float 0.001)) "p95 of single = 42.0" 42.0 p
;;

let test_performance_p95_unsorted () =
  (* The function should sort internally *)
  let p = Harness.Performance.p95 [ 100.0; 10.0; 50.0; 30.0; 70.0 ] in
  (* sorted: [10; 30; 50; 70; 100], idx = int(4 * 0.95) = 3 -> 70.0 *)
  Alcotest.(check (float 0.001)) "p95 of unsorted" 70.0 p
;;

let test_performance_latency_failure () =
  let obs : Harness.Performance.observation =
    { latencies_ms = [ 10.0; 20.0; 30.0; 40.0; 50.0 ]
    ; total_tokens = 2000
    ; total_cost_usd = 0.05
    ; turn_count = 8
    }
  in
  let exp : Harness.Performance.expectation = { max_p95_latency_ms = Some 35.0 } in
  let v = Harness.Performance.evaluate obs exp in
  Alcotest.(check bool) "latency failure" false v.passed;
  (* p95 40 > 35 *)
  Alcotest.(check bool) "detail lists failures" true (Option.is_some v.detail)
;;

let test_performance_no_constraints () =
  let obs : Harness.Performance.observation =
    { latencies_ms = [ 999.0 ]
    ; total_tokens = 999999
    ; total_cost_usd = 100.0
    ; turn_count = 100
    }
  in
  let v = Harness.Performance.evaluate obs Harness.Performance.default_expectation in
  Alcotest.(check bool) "no constraints -> pass" true v.passed;
  Alcotest.(check bool) "no evidence (no active checks)" true (v.evidence = [])
;;

let test_performance_latency_only () =
  let obs : Harness.Performance.observation =
    { latencies_ms = [ 10.0; 20.0; 30.0 ]
    ; total_tokens = 100
    ; total_cost_usd = 0.001
    ; turn_count = 1
    }
  in
  let exp : Harness.Performance.expectation = { max_p95_latency_ms = Some 25.0 } in
  let v = Harness.Performance.evaluate obs exp in
  (* p95 of [10;20;30] sorted, idx=int(2*0.95)=1 -> 20.0. 20 <= 25 -> pass *)
  Alcotest.(check bool) "latency within limit" true v.passed
;;

(* ── Regression: StructuralMatch and FuzzyMatch boundaries ── *)

let test_regression_structural_match () =
  let cmp a b = a = b in
  let obs : Harness.Regression.observation =
    { output_json = `Assoc [ "key", `String "val" ]; output_text = "ignored" }
  in
  let v = Harness.Regression.evaluate ~mode:(StructuralMatch cmp) obs {|{"key":"val"}|} in
  Alcotest.(check bool) "structural match" true v.passed
;;

let test_regression_structural_match_fail () =
  let cmp a b = a = b in
  let obs : Harness.Regression.observation =
    { output_json = `Assoc [ "key", `String "val" ]; output_text = "ignored" }
  in
  let v =
    Harness.Regression.evaluate ~mode:(StructuralMatch cmp) obs {|{"key":"different"}|}
  in
  Alcotest.(check bool) "structural mismatch" false v.passed
;;

let test_regression_structural_invalid_golden_json () =
  (* invalid golden JSON should fail instead of silently coercing to `Null *)
  let cmp a b = a = b in
  let obs : Harness.Regression.observation = { output_json = `Null; output_text = "x" } in
  let v = Harness.Regression.evaluate ~mode:(StructuralMatch cmp) obs "not json {{" in
  Alcotest.(check bool) "invalid golden fails" false v.passed
;;

let test_regression_fuzzy_threshold_boundary () =
  (* "abcde" vs "abcXX" -> common=3, max_len=5, similarity=0.6 *)
  let obs : Harness.Regression.observation =
    { output_json = `Null; output_text = "abcde" }
  in
  let v_pass =
    Harness.Regression.evaluate ~mode:(FuzzyMatch { threshold = 0.6 }) obs "abcXX"
  in
  Alcotest.(check bool) "fuzzy at threshold" true v_pass.passed;
  let v_fail =
    Harness.Regression.evaluate ~mode:(FuzzyMatch { threshold = 0.7 }) obs "abcXX"
  in
  Alcotest.(check bool) "fuzzy below threshold" false v_fail.passed
;;

let test_regression_fuzzy_empty_strings () =
  let obs : Harness.Regression.observation = { output_json = `Null; output_text = "" } in
  let v = Harness.Regression.evaluate ~mode:(FuzzyMatch { threshold = 0.5 }) obs "" in
  Alcotest.(check bool) "both empty -> pass" true v.passed
;;

let test_regression_fuzzy_different_lengths () =
  let obs : Harness.Regression.observation =
    { output_json = `Null; output_text = "short" }
  in
  let v =
    Harness.Regression.evaluate
      ~mode:(FuzzyMatch { threshold = 0.1 })
      obs
      "short and much longer text"
  in
  (* common chars: s,h,o,r,t = 5, max_len=26, ratio ~0.19 >= 0.1 *)
  Alcotest.(check bool) "different lengths" true v.passed
;;

(* ── Swiss Cheese: edge cases ──────────────────────────────── *)

let test_swiss_cheese_no_layers () =
  let v = Harness.Swiss_cheese.require_all [] "anything" in
  Alcotest.(check bool) "no layers -> pass" true v.passed;
  Alcotest.(check (float 0.01)) "coverage 1.0 for empty" 1.0 (Option.get v.score)
;;

let test_swiss_cheese_single_fail () =
  let failing_layer : string Harness.layer =
    { name = "always_fail"
    ; check = (fun _ -> false)
    ; evidence = (fun _ -> "always fails")
    }
  in
  let v = Harness.Swiss_cheese.require_all [ failing_layer ] "test" in
  Alcotest.(check bool) "single fail" false v.passed;
  Alcotest.(check (float 0.01)) "coverage 0.0" 0.0 (Option.get v.score);
  Alcotest.(check bool)
    "detail mentions failure"
    true
    (match v.detail with
     | Some d -> Util.string_contains ~needle:"1 layer" d
     | None -> false)
;;

let test_swiss_cheese_evaluate_layers () =
  let l1 : int Harness.layer =
    { name = "gt_zero"; check = (fun n -> n > 0); evidence = (fun n -> string_of_int n) }
  in
  let l2 : int Harness.layer =
    { name = "lt_hundred"
    ; check = (fun n -> n < 100)
    ; evidence = (fun n -> string_of_int n)
    }
  in
  let sv = Harness.Swiss_cheese.evaluate_layers [ l1; l2 ] 50 in
  Alcotest.(check bool) "all passed" true sv.all_passed;
  Alcotest.(check (float 0.01)) "coverage 1.0" 1.0 sv.coverage;
  Alcotest.(check int) "2 results" 2 (List.length sv.layer_results)
;;

let test_swiss_cheese_evaluate_layers_partial () =
  let l1 : int Harness.layer =
    { name = "positive"; check = (fun n -> n > 0); evidence = (fun n -> string_of_int n) }
  in
  let l2 : int Harness.layer =
    { name = "even"
    ; check = (fun n -> n mod 2 = 0)
    ; evidence = (fun n -> string_of_int n)
    }
  in
  let sv = Harness.Swiss_cheese.evaluate_layers [ l1; l2 ] 3 in
  Alcotest.(check bool) "not all passed" false sv.all_passed;
  Alcotest.(check (float 0.01)) "coverage 0.5" 0.5 sv.coverage
;;

let test_swiss_cheese_require_n_zero () =
  let v = Harness.Swiss_cheese.require_n 0 [] "x" in
  Alcotest.(check bool) "require 0 of 0 -> pass" true v.passed
;;

let test_swiss_cheese_require_n_more_than_available () =
  let l : string Harness.layer =
    { name = "trivial"; check = (fun _ -> true); evidence = (fun _ -> "ok") }
  in
  let v = Harness.Swiss_cheese.require_n 5 [ l ] "x" in
  Alcotest.(check bool) "need 5, have 1 -> fail" false v.passed;
  Alcotest.(check bool)
    "detail present"
    true
    (match v.detail with
     | Some d -> Util.string_contains ~needle:"Only 1" d
     | None -> false)
;;

(* ── Composability: remaining branches ─────────────────────── *)

let test_composability_all_agents_completed_true () =
  let obs : Harness.Composability.observation =
    { agents_involved = [ "a"; "b"; "c" ]
    ; handoffs_observed = []
    ; all_completed = true
    ; context_keys = []
    ; total_turns = 3
    }
  in
  let v = Harness.Composability.evaluate obs AllAgentsCompleted in
  Alcotest.(check bool) "all completed" true v.passed
;;

let test_composability_all_agents_completed_false () =
  let obs : Harness.Composability.observation =
    { agents_involved = [ "a"; "b" ]
    ; handoffs_observed = []
    ; all_completed = false
    ; context_keys = []
    ; total_turns = 5
    }
  in
  let v = Harness.Composability.evaluate obs AllAgentsCompleted in
  Alcotest.(check bool) "not completed" false v.passed;
  Alcotest.(check bool)
    "detail"
    true
    (match v.detail with
     | Some d -> Util.string_contains ~needle:"Not all" d
     | None -> false)
;;

let test_composability_context_not_propagated () =
  let obs : Harness.Composability.observation =
    { agents_involved = [ "a" ]
    ; handoffs_observed = []
    ; all_completed = true
    ; context_keys = [ "existing_key" ]
    ; total_turns = 1
    }
  in
  let v = Harness.Composability.evaluate obs (ContextPropagated "missing_key") in
  Alcotest.(check bool) "key missing" false v.passed;
  Alcotest.(check bool)
    "detail mentions key"
    true
    (match v.detail with
     | Some d -> Util.string_contains ~needle:"missing_key" d
     | None -> false)
;;

(* ── Behavioral: score aggregation in All ──────────────────── *)

let test_behavioral_all_without_scores () =
  let obs : Harness.Behavioral.observation =
    { tools_called = [ "search" ]
    ; turn_count = 2
    ; final_response = "Found it"
    ; messages = []
    }
  in
  let v =
    Harness.Behavioral.evaluate
      obs
      (All [ ToolSelected [ "search" ]; ContainsText "Found" ])
  in
  Alcotest.(check bool) "all pass" true v.passed;
  Alcotest.(check bool) "no numeric score" true (Option.is_none v.score)
;;

let test_behavioral_all_empty () =
  let obs : Harness.Behavioral.observation =
    { tools_called = []; turn_count = 0; final_response = ""; messages = [] }
  in
  let v = Harness.Behavioral.evaluate obs (All []) in
  Alcotest.(check bool) "empty All -> pass" true v.passed;
  Alcotest.(check bool) "no score for empty" true (Option.is_none v.score)
;;

let test_behavioral_tool_selected_evidence () =
  let obs : Harness.Behavioral.observation =
    { tools_called = [ "a"; "b" ]; turn_count = 1; final_response = ""; messages = [] }
  in
  let v = Harness.Behavioral.evaluate obs (ToolSelected [ "a"; "c" ]) in
  Alcotest.(check bool) "missing tool c" false v.passed;
  Alcotest.(check bool)
    "detail mentions missing"
    true
    (match v.detail with
     | Some d -> Util.string_contains ~needle:"c" d
     | None -> false)
;;

let test_behavioral_all_partial_failure_count () =
  let obs : Harness.Behavioral.observation =
    { tools_called = []; turn_count = 99; final_response = ""; messages = [] }
  in
  let v =
    Harness.Behavioral.evaluate
      obs
      (All [ ToolSelected [ "missing" ]; ContainsText "nope" ])
  in
  Alcotest.(check bool) "all fail" false v.passed;
  Alcotest.(check bool)
    "detail says 2/2"
    true
    (match v.detail with
     | Some d -> Util.string_contains ~needle:"2/2" d
     | None -> false)
;;

(* ── Test suite ──────────────────────────────────────────────── *)

let () =
  Alcotest.run
    "harness-deep"
    [ ( "adversarial-deep"
      , [ Alcotest.test_case
            "error_contains found"
            `Quick
            test_adversarial_error_contains_found
        ; Alcotest.test_case
            "error_contains not found"
            `Quick
            test_adversarial_error_contains_not_found
        ; Alcotest.test_case
            "error_contains none"
            `Quick
            test_adversarial_error_contains_none
        ; Alcotest.test_case
            "graceful_error ok result"
            `Quick
            test_adversarial_graceful_error_ok_result
        ; Alcotest.test_case
            "no_tool with tools"
            `Quick
            test_adversarial_no_tool_with_tools
        ] )
    ; ( "performance-deep"
      , [ Alcotest.test_case "p95 empty" `Quick test_performance_p95_empty
        ; Alcotest.test_case "p95 single" `Quick test_performance_p95_single
        ; Alcotest.test_case "p95 unsorted" `Quick test_performance_p95_unsorted
        ; Alcotest.test_case "latency failure" `Quick test_performance_latency_failure
        ; Alcotest.test_case "no constraints" `Quick test_performance_no_constraints
        ; Alcotest.test_case "latency only" `Quick test_performance_latency_only
        ] )
    ; ( "regression-deep"
      , [ Alcotest.test_case "structural match" `Quick test_regression_structural_match
        ; Alcotest.test_case
            "structural mismatch"
            `Quick
            test_regression_structural_match_fail
        ; Alcotest.test_case
            "structural invalid golden"
            `Quick
            test_regression_structural_invalid_golden_json
        ; Alcotest.test_case
            "fuzzy threshold boundary"
            `Quick
            test_regression_fuzzy_threshold_boundary
        ; Alcotest.test_case
            "fuzzy empty strings"
            `Quick
            test_regression_fuzzy_empty_strings
        ; Alcotest.test_case
            "fuzzy different lengths"
            `Quick
            test_regression_fuzzy_different_lengths
        ] )
    ; ( "swiss-cheese-deep"
      , [ Alcotest.test_case "no layers" `Quick test_swiss_cheese_no_layers
        ; Alcotest.test_case "single fail" `Quick test_swiss_cheese_single_fail
        ; Alcotest.test_case "evaluate layers" `Quick test_swiss_cheese_evaluate_layers
        ; Alcotest.test_case
            "evaluate layers partial"
            `Quick
            test_swiss_cheese_evaluate_layers_partial
        ; Alcotest.test_case "require_n zero" `Quick test_swiss_cheese_require_n_zero
        ; Alcotest.test_case
            "require_n exceed"
            `Quick
            test_swiss_cheese_require_n_more_than_available
        ] )
    ; ( "composability-deep"
      , [ Alcotest.test_case
            "all_completed true"
            `Quick
            test_composability_all_agents_completed_true
        ; Alcotest.test_case
            "all_completed false"
            `Quick
            test_composability_all_agents_completed_false
        ; Alcotest.test_case
            "context not propagated"
            `Quick
            test_composability_context_not_propagated
        ] )
    ; ( "behavioral-deep"
      , [ Alcotest.test_case
            "all without scores"
            `Quick
            test_behavioral_all_without_scores
        ; Alcotest.test_case "all empty" `Quick test_behavioral_all_empty
        ; Alcotest.test_case
            "tool_selected evidence"
            `Quick
            test_behavioral_tool_selected_evidence
        ; Alcotest.test_case
            "all partial failure count"
            `Quick
            test_behavioral_all_partial_failure_count
        ] )
    ]
;;
