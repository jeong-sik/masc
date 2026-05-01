(** test_reward_advice_artifact.ml — Unit tests for Reward_advice_artifact.

    Covers:
    - advice_source round-trip serialization
    - multiplier_of_verdict contract
    - of_post_verifier_verdict: pass/warn/fail mapping
    - of_benchmark_case_score: composite_score → multiplier bands
    - to_yojson / of_yojson round-trip
    - Post_verifier.to_reward_advice convenience wrapper
*)

module RAA = Masc_mcp.Reward_advice_artifact
module Pv  = Masc_mcp.Post_verifier

(* ================================================================ *)
(* Helpers                                                          *)
(* ================================================================ *)

let float_eps = 0.001

let make_case_score ?(case_id = "case-001") ?(provider = "test") ?(model = "m1")
    ?(keeper_profile = "default") composite_score : Masc_mcp.Tool_call_quality_benchmark_types.case_score =
  let cs = composite_score in
  {
    case_id;
    provider;
    model;
    keeper_profile;
    passed = cs = 1.0;
    task_pass = cs;
    tool_selection = cs;
    arg_validity = cs;
    recovery = 1.0;
    efficiency = cs;
    unnecessary_tool_rate = 0.0;
    composite_score = cs;
    tool_call_count = 3;
    latency_ms = Some 100;
    input_tokens = None;
    output_tokens = None;
    cost_usd = None;
    prompt_fingerprint = None;
    tool_sequence = [];
  }

(* ================================================================ *)
(* 1. Source round-trip                                             *)
(* ================================================================ *)

let test_source_round_trip () =
  let sources = [RAA.Post_verifier; RAA.Benchmark; RAA.Task_verifier] in
  List.iter (fun src ->
    let s = RAA.advice_source_to_string src in
    match RAA.advice_source_of_string s with
    | Some reparsed ->
      Alcotest.(check string)
        ("round-trip " ^ s)
        (RAA.advice_source_to_string src)
        (RAA.advice_source_to_string reparsed)
    | None ->
      Alcotest.fail (Printf.sprintf "advice_source_of_string %S returned None" s)
  ) sources

let test_source_unknown () =
  Alcotest.(check (option string))
    "unknown source → None"
    None
    (Option.map RAA.advice_source_to_string (RAA.advice_source_of_string "no_such_source"))

(* ================================================================ *)
(* 2. multiplier_of_verdict contract                                *)
(* ================================================================ *)

let test_multiplier_pass () =
  Alcotest.(check (float float_eps))
    "pass → 1.0" 1.0 (RAA.multiplier_of_verdict "pass")

let test_multiplier_warn () =
  Alcotest.(check (float float_eps))
    "warn → 0.8" 0.8 (RAA.multiplier_of_verdict "warn")

let test_multiplier_fail () =
  Alcotest.(check (float float_eps))
    "fail → 0.4" 0.4 (RAA.multiplier_of_verdict "fail")

let test_multiplier_unknown () =
  Alcotest.(check (float float_eps))
    "unknown → 1.0 (neutral)" 1.0 (RAA.multiplier_of_verdict "other")

(* ================================================================ *)
(* 3. of_post_verifier_verdict via Post_verifier.to_reward_advice   *)
(* ================================================================ *)

let test_post_verifier_pass () =
  let result = Pv.verify ~content:"A clear and substantive message." in
  let artifact = Pv.to_reward_advice ~agent_name:"agent-test" result in
  Alcotest.(check string) "source" "post_verifier"
    (RAA.advice_source_to_string artifact.source);
  Alcotest.(check string) "agent_name" "agent-test" artifact.agent_name;
  Alcotest.(check string) "verdict" "pass" artifact.verdict;
  Alcotest.(check (float float_eps)) "multiplier 1.0" 1.0 artifact.reward_multiplier;
  Alcotest.(check (float float_eps)) "confidence 1.0" 1.0 artifact.confidence;
  Alcotest.(check bool) "task_id absent" true (artifact.task_id = None)

let test_post_verifier_warn () =
  (* Short filler content triggers Warn in Post_verifier *)
  let result = Pv.verify ~content:"hello world" in
  Alcotest.(check bool) "result is warn" true
    (match result.overall with Pv.Warn _ -> true | _ -> false);
  let artifact = Pv.to_reward_advice ~agent_name:"agent-warn" ~task_id:"task-42" result in
  Alcotest.(check string) "verdict warn" "warn" artifact.verdict;
  Alcotest.(check (float float_eps)) "multiplier 0.8" 0.8 artifact.reward_multiplier;
  Alcotest.(check (float float_eps)) "confidence 0.9" 0.9 artifact.confidence;
  Alcotest.(check (option string)) "task_id present" (Some "task-42") artifact.task_id;
  Alcotest.(check bool) "advisory message non-empty" true
    (String.length artifact.advisory_message > 0)

let test_post_verifier_fail () =
  let result = Pv.verify ~content:"   \n\t  " in
  Alcotest.(check bool) "result is fail" true
    (match result.overall with Pv.Fail _ -> true | _ -> false);
  let artifact = Pv.to_reward_advice ~agent_name:"agent-fail" result in
  Alcotest.(check string) "verdict fail" "fail" artifact.verdict;
  Alcotest.(check (float float_eps)) "multiplier 0.4" 0.4 artifact.reward_multiplier;
  Alcotest.(check (float float_eps)) "confidence 1.0" 1.0 artifact.confidence

(* ================================================================ *)
(* 4. Post_verifier.to_reward_advice convenience wrapper            *)
(* ================================================================ *)

let test_post_verifier_to_reward_advice_pass () =
  let result = Pv.verify ~content:"Solid engineering work done." in
  let artifact = Pv.to_reward_advice ~agent_name:"keeper-1" result in
  Alcotest.(check string) "verdict" "pass" artifact.verdict;
  Alcotest.(check string) "source" "post_verifier"
    (RAA.advice_source_to_string artifact.source)

(* ================================================================ *)
(* 5. of_benchmark_case_score                                       *)
(* ================================================================ *)

let test_benchmark_high_score () =
  (* composite_score = 0.9 → pass band → multiplier 1.1 *)
  let score = make_case_score 0.9 in
  let artifact = RAA.of_benchmark_case_score ~agent_name:"bench-agent" score in
  Alcotest.(check string) "source" "benchmark"
    (RAA.advice_source_to_string artifact.source);
  Alcotest.(check string) "verdict pass" "pass" artifact.verdict;
  Alcotest.(check (float float_eps)) "multiplier 1.1" 1.1 artifact.reward_multiplier;
  Alcotest.(check bool) "evidence_refs non-empty" true
    (artifact.evidence_refs <> [])

let test_benchmark_mid_score () =
  (* composite_score = 0.65 → warn band → multiplier 0.9 *)
  let score = make_case_score 0.65 in
  let artifact = RAA.of_benchmark_case_score ~agent_name:"bench-agent" score in
  Alcotest.(check string) "verdict warn" "warn" artifact.verdict;
  Alcotest.(check (float float_eps)) "multiplier 0.9" 0.9 artifact.reward_multiplier

let test_benchmark_low_score () =
  (* composite_score = 0.3 → fail band → multiplier 0.5 *)
  let score = make_case_score 0.3 in
  let artifact = RAA.of_benchmark_case_score
    ~agent_name:"bench-agent" ~task_id:"task-low" score in
  Alcotest.(check string) "verdict fail" "fail" artifact.verdict;
  Alcotest.(check (float float_eps)) "multiplier 0.5" 0.5 artifact.reward_multiplier;
  Alcotest.(check (option string)) "task_id" (Some "task-low") artifact.task_id

let test_benchmark_boundary_08 () =
  (* exactly 0.8 → pass band *)
  let score = make_case_score 0.8 in
  let artifact = RAA.of_benchmark_case_score ~agent_name:"agent" score in
  Alcotest.(check string) "verdict pass at 0.8" "pass" artifact.verdict

let test_benchmark_boundary_05 () =
  (* exactly 0.5 → warn band *)
  let score = make_case_score 0.5 in
  let artifact = RAA.of_benchmark_case_score ~agent_name:"agent" score in
  Alcotest.(check string) "verdict warn at 0.5" "warn" artifact.verdict

let test_benchmark_with_fingerprint () =
  let score = { (make_case_score 0.9) with
    prompt_fingerprint = Some "fp-abc123" } in
  let artifact = RAA.of_benchmark_case_score ~agent_name:"agent" score in
  Alcotest.(check bool) "fingerprint ref present" true
    (List.exists (fun r -> String_util.contains_substring r "fp-abc123")
       artifact.evidence_refs)

(* ================================================================ *)
(* 6. to_yojson / of_yojson round-trip                             *)
(* ================================================================ *)

let test_json_round_trip_pass () =
  let result = Pv.verify ~content:"Normal content that passes all checks." in
  let orig = Pv.to_reward_advice ~agent_name:"rt-agent" ~task_id:"rt-task" result in
  let json = RAA.to_yojson orig in
  match RAA.of_yojson json with
  | Error e -> Alcotest.fail ("of_yojson error: " ^ e)
  | Ok reparsed ->
    Alcotest.(check string) "agent_name" orig.agent_name reparsed.agent_name;
    Alcotest.(check (option string)) "task_id" orig.task_id reparsed.task_id;
    Alcotest.(check string) "verdict" orig.verdict reparsed.verdict;
    Alcotest.(check (float float_eps))
      "reward_multiplier" orig.reward_multiplier reparsed.reward_multiplier;
    Alcotest.(check string) "advisory_message" orig.advisory_message reparsed.advisory_message;
    Alcotest.(check (float float_eps)) "confidence" orig.confidence reparsed.confidence;
    Alcotest.(check string) "source"
      (RAA.advice_source_to_string orig.source)
      (RAA.advice_source_to_string reparsed.source)

let test_json_round_trip_benchmark () =
  let score = make_case_score ~case_id:"rt-case" 0.72 in
  let orig = RAA.of_benchmark_case_score ~agent_name:"rt-bench" score in
  let json = RAA.to_yojson orig in
  match RAA.of_yojson json with
  | Error e -> Alcotest.fail ("of_yojson error: " ^ e)
  | Ok reparsed ->
    Alcotest.(check string) "case_id in evidence" "benchmark:rt-case"
      (List.hd reparsed.evidence_refs);
    Alcotest.(check (float float_eps))
      "multiplier preserved" orig.reward_multiplier reparsed.reward_multiplier

let test_json_missing_agent_name () =
  let json = `Assoc [ ("source", `String "post_verifier"); ("agent_name", `String "") ] in
  match RAA.of_yojson json with
  | Error _ -> ()  (* expected *)
  | Ok _ -> Alcotest.fail "expected error for empty agent_name"

let test_json_unknown_source () =
  let json = `Assoc [ ("source", `String "unknown_src"); ("agent_name", `String "a") ] in
  match RAA.of_yojson json with
  | Error _ -> ()  (* expected *)
  | Ok _ -> Alcotest.fail "expected error for unknown source"

let test_json_multiplier_clamped () =
  (* of_yojson should clamp multiplier to [0.0, 2.0] *)
  let json = `Assoc [
    ("source", `String "benchmark");
    ("agent_name", `String "agent");
    ("verdict", `String "pass");
    ("reward_multiplier", `Float 99.0);
    ("confidence", `Float 1.0);
    ("timestamp", `Float 0.0);
  ] in
  match RAA.of_yojson json with
  | Error e -> Alcotest.fail ("unexpected error: " ^ e)
  | Ok a ->
    Alcotest.(check (float float_eps)) "clamped to 2.0" 2.0 a.reward_multiplier

(* ================================================================ *)
(* Runner                                                           *)
(* ================================================================ *)

let () =
  Alcotest.run "Reward_advice_artifact"
    [
      ( "source",
        [
          Alcotest.test_case "round-trip" `Quick test_source_round_trip;
          Alcotest.test_case "unknown → None" `Quick test_source_unknown;
        ] );
      ( "multiplier_of_verdict",
        [
          Alcotest.test_case "pass → 1.0" `Quick test_multiplier_pass;
          Alcotest.test_case "warn → 0.8" `Quick test_multiplier_warn;
          Alcotest.test_case "fail → 0.4" `Quick test_multiplier_fail;
          Alcotest.test_case "unknown → 1.0" `Quick test_multiplier_unknown;
        ] );
      ( "post_verifier_to_reward_advice",
        [
          Alcotest.test_case "pass content" `Quick test_post_verifier_pass;
          Alcotest.test_case "warn content" `Quick test_post_verifier_warn;
          Alcotest.test_case "fail content" `Quick test_post_verifier_fail;
          Alcotest.test_case "advisory message for pass" `Quick
            test_post_verifier_to_reward_advice_pass;
        ] );
      ( "of_benchmark_case_score",
        [
          Alcotest.test_case "high score → pass 1.1" `Quick test_benchmark_high_score;
          Alcotest.test_case "mid score → warn 0.9" `Quick test_benchmark_mid_score;
          Alcotest.test_case "low score → fail 0.5" `Quick test_benchmark_low_score;
          Alcotest.test_case "boundary 0.8 → pass" `Quick test_benchmark_boundary_08;
          Alcotest.test_case "boundary 0.5 → warn" `Quick test_benchmark_boundary_05;
          Alcotest.test_case "fingerprint in evidence_refs" `Quick
            test_benchmark_with_fingerprint;
        ] );
      ( "json_serialization",
        [
          Alcotest.test_case "post_verifier round-trip" `Quick test_json_round_trip_pass;
          Alcotest.test_case "benchmark round-trip" `Quick test_json_round_trip_benchmark;
          Alcotest.test_case "missing agent_name → error" `Quick
            test_json_missing_agent_name;
          Alcotest.test_case "unknown source → error" `Quick test_json_unknown_source;
          Alcotest.test_case "multiplier clamped" `Quick test_json_multiplier_clamped;
        ] );
    ]
