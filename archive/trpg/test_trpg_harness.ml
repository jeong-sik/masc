(** test_trpg_harness.ml — Unit tests for Trpg_harness parser + scoring logic.

    Tests only deterministic functions (parsers, weights, serialization).
    LLM-dependent functions are tested via integration tests.

    @since 2.70.0 *)

open Masc_mcp

(* ---- helpers ---- *)
let float_eq ~eps a b = Float.abs (a -. b) < eps

let check_float msg ~eps expected actual =
  Alcotest.(check bool) msg true (float_eq ~eps expected actual)

(* ==================================================================== *)
(* Tier 1 parser tests                                                   *)
(* ==================================================================== *)

let test_parse_tier1_pass () =
  match Trpg_harness.parse_tier1 "PASS" with
  | Pass -> ()
  | Fail r -> Alcotest.fail ("expected Pass, got Fail: " ^ r)

let test_parse_tier1_pass_lowercase () =
  match Trpg_harness.parse_tier1 "pass" with
  | Pass -> ()
  | Fail r -> Alcotest.fail ("expected Pass, got Fail: " ^ r)

let test_parse_tier1_pass_with_trailing () =
  match Trpg_harness.parse_tier1 "PASS - looks good" with
  | Pass -> ()
  | Fail r -> Alcotest.fail ("expected Pass, got Fail: " ^ r)

let test_parse_tier1_fail_with_reason () =
  match Trpg_harness.parse_tier1 "FAIL: empty response" with
  | Fail reason ->
    Alcotest.(check string) "reason extracted" "empty response" reason
  | Pass -> Alcotest.fail "expected Fail, got Pass"

let test_parse_tier1_fail_dash_reason () =
  match Trpg_harness.parse_tier1 "FAIL- gibberish detected" with
  | Fail reason ->
    Alcotest.(check string) "reason extracted" "gibberish detected" reason
  | Pass -> Alcotest.fail "expected Fail, got Pass"

let test_parse_tier1_fail_bare () =
  match Trpg_harness.parse_tier1 "FAIL" with
  | Fail reason ->
    Alcotest.(check string) "default reason" "structural check failed" reason
  | Pass -> Alcotest.fail "expected Fail, got Pass"

let test_parse_tier1_garbage () =
  match Trpg_harness.parse_tier1 "I don't know what to say" with
  | Fail reason ->
    Alcotest.(check string) "unparseable" "unparseable response" reason
  | Pass -> Alcotest.fail "expected Fail for garbage input"

let test_parse_tier1_whitespace () =
  match Trpg_harness.parse_tier1 "  PASS  \n" with
  | Pass -> ()
  | Fail r -> Alcotest.fail ("expected Pass, got Fail: " ^ r)

(* ==================================================================== *)
(* Tier 2 parser tests                                                   *)
(* ==================================================================== *)

let test_parse_tier2_full () =
  let text =
    "CHARACTER_FIDELITY: 4 stays in role consistently\n\
     HUMAN_LIKENESS: 3 somewhat natural\n\
     NARRATIVE_CONSISTENCY: 5 perfectly aligned with scene"
  in
  let scores = Trpg_harness.parse_tier2 text in
  Alcotest.(check int) "3 dimensions" 3 (List.length scores);
  let cf = List.hd scores in
  check_float "character_fidelity score" ~eps:0.01 4.0 cf.score;
  Alcotest.(check string) "cf reason" "stays in role consistently" cf.reason;
  let hl = List.nth scores 1 in
  check_float "human_likeness score" ~eps:0.01 3.0 hl.score;
  let nc = List.nth scores 2 in
  check_float "narrative_consistency score" ~eps:0.01 5.0 nc.score

let test_parse_tier2_missing_dimension () =
  let text =
    "CHARACTER_FIDELITY: 4 good\n\
     NARRATIVE_CONSISTENCY: 2 not great"
  in
  let scores = Trpg_harness.parse_tier2 text in
  Alcotest.(check int) "3 dimensions" 3 (List.length scores);
  (* human_likeness missing → default 3.0 *)
  let hl = List.nth scores 1 in
  check_float "default score" ~eps:0.01 3.0 hl.score;
  Alcotest.(check string) "default reason" "not evaluated" hl.reason

let test_parse_tier2_bare_digits () =
  let text =
    "CHARACTER_FIDELITY: 5\n\
     HUMAN_LIKENESS: 1\n\
     NARRATIVE_CONSISTENCY: 3"
  in
  let scores = Trpg_harness.parse_tier2 text in
  let cf = List.hd scores in
  check_float "bare digit 5" ~eps:0.01 5.0 cf.score;
  let hl = List.nth scores 1 in
  check_float "bare digit 1" ~eps:0.01 1.0 hl.score;
  let nc = List.nth scores 2 in
  check_float "bare digit 3" ~eps:0.01 3.0 nc.score

let test_parse_tier2_noisy_prefix () =
  (* LLM sometimes adds extra text before the scores *)
  let text =
    "Here are my scores:\n\
     CHARACTER_FIDELITY: 4 mostly in character\n\
     HUMAN_LIKENESS: 3 decent\n\
     NARRATIVE_CONSISTENCY: 4 good flow"
  in
  let scores = Trpg_harness.parse_tier2 text in
  let cf = List.hd scores in
  check_float "cf despite noise" ~eps:0.01 4.0 cf.score

(* ==================================================================== *)
(* Weighted scoring tests                                                *)
(* ==================================================================== *)

let test_weighted_total_perfect () =
  let scores =
    [
      { Trpg_harness.dimension = Character_fidelity; score = 5.0; reason = "" };
      { dimension = Human_likeness; score = 5.0; reason = "" };
      { dimension = Narrative_consistency; score = 5.0; reason = "" };
    ]
  in
  let total = Trpg_harness.compute_weighted_total scores in
  (* (5*0.4 + 5*0.3 + 5*0.3) / 5 = 5/5 = 1.0 *)
  check_float "perfect score = 1.0" ~eps:0.001 1.0 total

let test_weighted_total_minimum () =
  let scores =
    [
      { Trpg_harness.dimension = Character_fidelity; score = 1.0; reason = "" };
      { dimension = Human_likeness; score = 1.0; reason = "" };
      { dimension = Narrative_consistency; score = 1.0; reason = "" };
    ]
  in
  let total = Trpg_harness.compute_weighted_total scores in
  (* (1*0.4 + 1*0.3 + 1*0.3) / 5 = 1/5 = 0.2 *)
  check_float "minimum score = 0.2" ~eps:0.001 0.2 total

let test_weighted_total_mixed () =
  let scores =
    [
      { Trpg_harness.dimension = Character_fidelity; score = 4.0; reason = "" };
      { dimension = Human_likeness; score = 3.0; reason = "" };
      { dimension = Narrative_consistency; score = 5.0; reason = "" };
    ]
  in
  let total = Trpg_harness.compute_weighted_total scores in
  (* (4*0.4 + 3*0.3 + 5*0.3) / 5 = (1.6+0.9+1.5)/5 = 4.0/5 = 0.8 *)
  check_float "mixed score = 0.8" ~eps:0.001 0.8 total

(* ==================================================================== *)
(* Serialization tests                                                   *)
(* ==================================================================== *)

let test_result_to_yojson_pass () =
  let result : Trpg_harness.evaluation_result =
    {
      tier1 = Pass;
      scores =
        [
          { dimension = Character_fidelity; score = 4.0; reason = "good" };
          { dimension = Human_likeness; score = 3.0; reason = "ok" };
          { dimension = Narrative_consistency; score = 5.0; reason = "great" };
        ];
      weighted_total = 0.8;
      raw_response = "";
      evaluated_at = "2026-02-24T00:00:00Z";
    }
  in
  let json = Trpg_harness.result_to_yojson result in
  match json with
  | `Assoc fields ->
    (* tier1 = "pass" *)
    (match List.assoc_opt "tier1" fields with
     | Some (`String "pass") -> ()
     | _ -> Alcotest.fail "tier1 should be 'pass'");
    (* scores is a list of 3 *)
    (match List.assoc_opt "scores" fields with
     | Some (`List l) ->
       Alcotest.(check int) "3 scores" 3 (List.length l)
     | _ -> Alcotest.fail "scores should be a list");
    (* weighted_total is float *)
    (match List.assoc_opt "weighted_total" fields with
     | Some (`Float f) ->
       check_float "weighted_total" ~eps:0.001 0.8 f
     | _ -> Alcotest.fail "weighted_total should be float")
  | _ -> Alcotest.fail "top-level should be Assoc"

let test_result_to_yojson_fail () =
  let result : Trpg_harness.evaluation_result =
    {
      tier1 = Fail "empty response";
      scores = [];
      weighted_total = 0.0;
      raw_response = "";
      evaluated_at = "2026-02-24T00:00:00Z";
    }
  in
  let json = Trpg_harness.result_to_yojson result in
  match json with
  | `Assoc fields ->
    (match List.assoc_opt "tier1" fields with
     | Some (`String s) ->
       Alcotest.(check bool) "starts with fail:" true
         (String.length s >= 5
          && String.sub s 0 5 = "fail:")
     | _ -> Alcotest.fail "tier1 should be string");
    (match List.assoc_opt "scores" fields with
     | Some (`List []) -> ()
     | _ -> Alcotest.fail "scores should be empty list")
  | _ -> Alcotest.fail "top-level should be Assoc"

let test_string_of_dimension () =
  Alcotest.(check string) "cf"
    "character_fidelity"
    (Trpg_harness.string_of_dimension Character_fidelity);
  Alcotest.(check string) "hl"
    "human_likeness"
    (Trpg_harness.string_of_dimension Human_likeness);
  Alcotest.(check string) "nc"
    "narrative_consistency"
    (Trpg_harness.string_of_dimension Narrative_consistency)

(* ==================================================================== *)
(* Test runner                                                           *)
(* ==================================================================== *)

let () =
  Alcotest.run "trpg_harness"
    [
      ( "tier1_parser",
        [
          Alcotest.test_case "PASS" `Quick test_parse_tier1_pass;
          Alcotest.test_case "pass lowercase" `Quick test_parse_tier1_pass_lowercase;
          Alcotest.test_case "PASS with trailing" `Quick test_parse_tier1_pass_with_trailing;
          Alcotest.test_case "FAIL with reason" `Quick test_parse_tier1_fail_with_reason;
          Alcotest.test_case "FAIL dash reason" `Quick test_parse_tier1_fail_dash_reason;
          Alcotest.test_case "FAIL bare" `Quick test_parse_tier1_fail_bare;
          Alcotest.test_case "garbage input" `Quick test_parse_tier1_garbage;
          Alcotest.test_case "whitespace" `Quick test_parse_tier1_whitespace;
        ] );
      ( "tier2_parser",
        [
          Alcotest.test_case "full parse" `Quick test_parse_tier2_full;
          Alcotest.test_case "missing dimension" `Quick test_parse_tier2_missing_dimension;
          Alcotest.test_case "bare digits" `Quick test_parse_tier2_bare_digits;
          Alcotest.test_case "noisy prefix" `Quick test_parse_tier2_noisy_prefix;
        ] );
      ( "weighted_scoring",
        [
          Alcotest.test_case "perfect" `Quick test_weighted_total_perfect;
          Alcotest.test_case "minimum" `Quick test_weighted_total_minimum;
          Alcotest.test_case "mixed" `Quick test_weighted_total_mixed;
        ] );
      ( "serialization",
        [
          Alcotest.test_case "pass result" `Quick test_result_to_yojson_pass;
          Alcotest.test_case "fail result" `Quick test_result_to_yojson_fail;
          Alcotest.test_case "string_of_dimension" `Quick test_string_of_dimension;
        ] );
    ]
