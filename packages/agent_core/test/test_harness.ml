(** Tests for the Harness module — behavioral, adversarial, performance,
    regression, swiss cheese, and composability verification. *)

open Agent_sdk

(* ── Behavioral harness tests ────────────────────────────────── *)

let test_behavioral_tool_selected () =
  let obs : Harness.Behavioral.observation =
    { tools_called = [ "get_weather"; "search" ]
    ; turn_count = 3
    ; final_response = "The weather is sunny."
    ; messages = []
    }
  in
  let verdict = Harness.Behavioral.evaluate obs (ToolSelected [ "get_weather" ]) in
  Alcotest.(check bool) "tool found" true verdict.passed;
  let verdict2 = Harness.Behavioral.evaluate obs (ToolSelected [ "missing_tool" ]) in
  Alcotest.(check bool) "tool not found" false verdict2.passed
;;

let test_behavioral_contains_text () =
  let obs : Harness.Behavioral.observation =
    { tools_called = []
    ; turn_count = 1
    ; final_response = "The weather in Seoul is sunny."
    ; messages = []
    }
  in
  let verdict = Harness.Behavioral.evaluate obs (ContainsText "Seoul") in
  Alcotest.(check bool) "text found" true verdict.passed;
  let verdict2 = Harness.Behavioral.evaluate obs (ContainsText "Tokyo") in
  Alcotest.(check bool) "text not found" false verdict2.passed
;;

let test_behavioral_all () =
  let obs : Harness.Behavioral.observation =
    { tools_called = [ "search" ]
    ; turn_count = 2
    ; final_response = "Found results"
    ; messages = []
    }
  in
  let verdict =
    Harness.Behavioral.evaluate
      obs
      (All [ ToolSelected [ "search" ]; ContainsText "Found" ])
  in
  Alcotest.(check bool) "all pass" true verdict.passed;
  let verdict2 =
    Harness.Behavioral.evaluate
      obs
      (All [ ToolSelected [ "missing" ]; ContainsText "Found" ])
  in
  Alcotest.(check bool) "one fails" false verdict2.passed
;;

(* ── Adversarial harness tests ───────────────────────────────── *)

let test_adversarial_graceful_error () =
  let obs : Harness.Adversarial.observation =
    { result = Error (Error.Internal "test error")
    ; tools_executed = []
    ; error_message = Some "test error"
    }
  in
  let verdict = Harness.Adversarial.evaluate obs GracefulError in
  Alcotest.(check bool) "error is graceful" true verdict.passed
;;

let test_adversarial_no_tool_execution () =
  let obs : Harness.Adversarial.observation =
    { result =
        Ok
          { id = "test"
          ; model = "test"
          ; stop_reason = Types.EndTurn
          ; content = [ Types.Text "ok" ]
          ; usage = None
          ; telemetry = None
          }
    ; tools_executed = []
    ; error_message = None
    }
  in
  let verdict = Harness.Adversarial.evaluate obs NoToolExecution in
  Alcotest.(check bool) "no tools" true verdict.passed;
  let obs2 = { obs with tools_executed = [ "dangerous_tool" ] } in
  let verdict2 = Harness.Adversarial.evaluate obs2 NoToolExecution in
  Alcotest.(check bool) "tools executed" false verdict2.passed
;;

(* ── Performance harness tests ───────────────────────────────── *)

let test_performance_p95 () =
  let latencies = [ 10.0; 20.0; 30.0; 40.0; 50.0; 60.0; 70.0; 80.0; 90.0; 100.0 ] in
  let p = Harness.Performance.p95 latencies in
  (* idx = int(9 * 0.95) = 8 → 90.0 (0-indexed) *)
  Alcotest.(check (float 1.0)) "p95 = 90" 90.0 p
;;

let test_performance_evaluate () =
  let obs : Harness.Performance.observation =
    { latencies_ms = [ 10.0; 20.0; 30.0 ]
    ; total_tokens = 500
    ; total_cost_usd = 0.01
    ; turn_count = 3
    }
  in
  let exp : Harness.Performance.expectation = { max_p95_latency_ms = Some 25.0 } in
  let verdict = Harness.Performance.evaluate obs exp in
  Alcotest.(check bool) "within latency target" true verdict.passed
;;

(* ── Regression harness tests ────────────────────────────────── *)

let test_regression_exact_match () =
  let obs : Harness.Regression.observation =
    { output_json = `String "hello"; output_text = "hello world" }
  in
  let v1 = Harness.Regression.evaluate ~mode:ExactMatch obs "hello world" in
  Alcotest.(check bool) "exact match" true v1.passed;
  let v2 = Harness.Regression.evaluate ~mode:ExactMatch obs "different" in
  Alcotest.(check bool) "exact mismatch" false v2.passed
;;

let test_regression_fuzzy_match () =
  let obs : Harness.Regression.observation =
    { output_json = `Null; output_text = "hello world" }
  in
  let v =
    Harness.Regression.evaluate ~mode:(FuzzyMatch { threshold = 0.5 }) obs "hello earth"
  in
  Alcotest.(check bool) "fuzzy match" true v.passed
;;

(* ── Swiss Cheese tests ──────────────────────────────────────── *)

let test_swiss_cheese_all_pass () =
  let layer1 : string Harness.layer =
    { name = "length_check"
    ; check = (fun s -> String.length s > 0)
    ; evidence = (fun s -> Printf.sprintf "len=%d" (String.length s))
    }
  in
  let layer2 : string Harness.layer =
    { name = "contains_hello"
    ; check = (fun s -> String.length s >= 5 && String.sub s 0 5 = "hello")
    ; evidence = (fun _s -> "starts_with_hello")
    }
  in
  let verdict = Harness.Swiss_cheese.require_all [ layer1; layer2 ] "hello world" in
  Alcotest.(check bool) "all layers pass" true verdict.passed;
  Alcotest.(check (float 0.01)) "coverage 1.0" 1.0 (Option.get verdict.score)
;;

let test_swiss_cheese_require_n () =
  let layer1 : int Harness.layer =
    { name = "positive"
    ; check = (fun n -> n > 0)
    ; evidence = (fun n -> Printf.sprintf "n=%d" n)
    }
  in
  let layer2 : int Harness.layer =
    { name = "even"
    ; check = (fun n -> n mod 2 = 0)
    ; evidence = (fun n -> Printf.sprintf "n=%d mod 2 = %d" n (n mod 2))
    }
  in
  let layer3 : int Harness.layer =
    { name = "less_than_10"
    ; check = (fun n -> n < 10)
    ; evidence = (fun n -> Printf.sprintf "n=%d < 10" n)
    }
  in
  (* n=3: positive=true, even=false, less_than_10=true → 2/3 *)
  let verdict = Harness.Swiss_cheese.require_n 2 [ layer1; layer2; layer3 ] 3 in
  Alcotest.(check bool) "2 of 3 pass" true verdict.passed;
  let verdict2 = Harness.Swiss_cheese.require_n 3 [ layer1; layer2; layer3 ] 3 in
  Alcotest.(check bool) "need all 3, only 2 pass" false verdict2.passed
;;

(* ── Composability harness tests ─────────────────────────────── *)

let test_composability_handoff () =
  let obs : Harness.Composability.observation =
    { agents_involved = [ "main"; "specialist" ]
    ; handoffs_observed = [ "main", "specialist" ]
    ; all_completed = true
    ; context_keys = [ "task_result" ]
    ; total_turns = 5
    }
  in
  let v = Harness.Composability.evaluate obs (HandoffOccurred "specialist") in
  Alcotest.(check bool) "handoff observed" true v.passed;
  let v2 = Harness.Composability.evaluate obs (HandoffOccurred "unknown") in
  Alcotest.(check bool) "handoff not observed" false v2.passed
;;

let test_composability_context_propagated () =
  let obs : Harness.Composability.observation =
    { agents_involved = [ "a"; "b" ]
    ; handoffs_observed = []
    ; all_completed = true
    ; context_keys = [ "shared_result"; "metadata" ]
    ; total_turns = 3
    }
  in
  let v = Harness.Composability.evaluate obs (ContextPropagated "shared_result") in
  Alcotest.(check bool) "key propagated" true v.passed
;;

(* ── Test suite ──────────────────────────────────────────────── *)

let () =
  Alcotest.run
    "harness"
    [ ( "behavioral"
      , [ Alcotest.test_case "tool_selected" `Quick test_behavioral_tool_selected
        ; Alcotest.test_case "contains_text" `Quick test_behavioral_contains_text
        ; Alcotest.test_case "all" `Quick test_behavioral_all
        ] )
    ; ( "adversarial"
      , [ Alcotest.test_case "graceful_error" `Quick test_adversarial_graceful_error
        ; Alcotest.test_case "no_tool_execution" `Quick test_adversarial_no_tool_execution
        ] )
    ; ( "performance"
      , [ Alcotest.test_case "p95" `Quick test_performance_p95
        ; Alcotest.test_case "evaluate" `Quick test_performance_evaluate
        ] )
    ; ( "regression"
      , [ Alcotest.test_case "exact_match" `Quick test_regression_exact_match
        ; Alcotest.test_case "fuzzy_match" `Quick test_regression_fuzzy_match
        ] )
    ; ( "swiss_cheese"
      , [ Alcotest.test_case "all_pass" `Quick test_swiss_cheese_all_pass
        ; Alcotest.test_case "require_n" `Quick test_swiss_cheese_require_n
        ] )
    ; ( "composability"
      , [ Alcotest.test_case "handoff" `Quick test_composability_handoff
        ; Alcotest.test_case
            "context_propagated"
            `Quick
            test_composability_context_propagated
        ] )
    ]
;;
