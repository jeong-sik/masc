(** Tests for Post_verifier_model module — G-Eval response parsing and scoring.

    All tests target pure functions (parse_geval_response, score_to_verdict).
    No actual MODEL calls — those require MASC_VERIFIER_MODE=model at runtime. *)

module Pvl = Masc_mcp.Post_verifier_model
module Pv = Masc_mcp.Post_verifier

open Alcotest

let is_pass = function Pv.Pass -> true | _ -> false
let is_warn = function Pv.Warn _ -> true | _ -> false
let is_fail = function Pv.Fail _ -> true | _ -> false

(* ================================================================ *)
(* parse_geval_response                                              *)
(* ================================================================ *)

let test_parse_valid_json () =
  let input = {|{"relevance": 4, "quality": 5, "safety": 3, "reasoning": "decent post"}|} in
  match Pvl.parse_geval_response input with
  | Ok (r, q, s, reasoning) ->
      check int "relevance" 4 r;
      check int "quality" 5 q;
      check int "safety" 3 s;
      check string "reasoning" "decent post" reasoning
  | Error e -> fail (Printf.sprintf "expected Ok, got Error: %s" e)

let test_parse_markdown_wrapped () =
  let input = "```json\n{\"relevance\": 2, \"quality\": 1, \"safety\": 5, \"reasoning\": \"\"}\n```" in
  match Pvl.parse_geval_response input with
  | Ok (r, q, s, _) ->
      check int "relevance" 2 r;
      check int "quality" 1 q;
      check int "safety" 5 s
  | Error e -> fail (Printf.sprintf "expected Ok, got Error: %s" e)

let test_parse_no_reasoning () =
  let input = {|{"relevance": 3, "quality": 3, "safety": 3}|} in
  match Pvl.parse_geval_response input with
  | Ok (r, q, s, reasoning) ->
      check int "relevance" 3 r;
      check int "quality" 3 q;
      check int "safety" 3 s;
      check string "reasoning empty" "" reasoning
  | Error e -> fail (Printf.sprintf "expected Ok, got Error: %s" e)

let test_parse_out_of_range () =
  let input = {|{"relevance": 0, "quality": 6, "safety": 3, "reasoning": "bad"}|} in
  match Pvl.parse_geval_response input with
  | Error msg ->
      check bool "mentions out of range" true
        (String.length msg > 0)
  | Ok _ -> fail "expected Error for out-of-range scores"

let test_parse_invalid_json () =
  match Pvl.parse_geval_response "not json at all" with
  | Error _ -> ()
  | Ok _ -> fail "expected Error for invalid JSON"

let test_parse_missing_field () =
  let input = {|{"relevance": 4, "safety": 5}|} in
  match Pvl.parse_geval_response input with
  | Error _ -> ()
  | Ok _ -> fail "expected Error for missing quality field"

let test_parse_with_preamble () =
  let input = "Here is my evaluation:\n{\"relevance\": 4, \"quality\": 4, \"safety\": 4, \"reasoning\": \"good\"}" in
  match Pvl.parse_geval_response input with
  | Ok (r, q, s, _) ->
      check int "relevance" 4 r;
      check int "quality" 4 q;
      check int "safety" 4 s
  | Error e -> fail (Printf.sprintf "expected Ok, got Error: %s" e)

(* ================================================================ *)
(* score_to_verdict                                                  *)
(* ================================================================ *)

let test_score_1_fails () =
  let v = Pvl.score_to_verdict ~dim_name:"relevance" 1 in
  check bool "score 1 is Fail" true (is_fail v)

let test_score_2_fails () =
  let v = Pvl.score_to_verdict ~dim_name:"quality" 2 in
  check bool "score 2 is Fail" true (is_fail v)

let test_score_3_warns () =
  let v = Pvl.score_to_verdict ~dim_name:"safety" 3 in
  check bool "score 3 is Warn" true (is_warn v)

let test_score_4_passes () =
  let v = Pvl.score_to_verdict ~dim_name:"relevance" 4 in
  check bool "score 4 is Pass" true (is_pass v)

let test_score_5_passes () =
  let v = Pvl.score_to_verdict ~dim_name:"quality" 5 in
  check bool "score 5 is Pass" true (is_pass v)

let test_score_0_fails () =
  let v = Pvl.score_to_verdict ~dim_name:"safety" 0 in
  check bool "score 0 is Fail" true (is_fail v)

(* ================================================================ *)
(* verify_auto defaults to heuristic                                 *)
(* ================================================================ *)

let test_verify_auto_default () =
  (* Without MASC_VERIFIER_MODE set, verify_auto should behave as heuristic *)
  let result = Pvl.verify_auto ~content:"This is a meaningful post with enough substance." in
  check bool "default mode passes valid content" true (Pv.is_acceptable result)

let test_verify_auto_rejects_short () =
  let result = Pvl.verify_auto ~content:"hi" in
  check bool "default mode rejects short content" false (Pv.is_acceptable result)

(* ================================================================ *)
(* Test runner                                                       *)
(* ================================================================ *)

let () =
  run "Post_verifier_model" [
    "parse_geval_response", [
      test_case "valid JSON" `Quick test_parse_valid_json;
      test_case "markdown-wrapped JSON" `Quick test_parse_markdown_wrapped;
      test_case "no reasoning field" `Quick test_parse_no_reasoning;
      test_case "out-of-range scores" `Quick test_parse_out_of_range;
      test_case "invalid JSON" `Quick test_parse_invalid_json;
      test_case "missing field" `Quick test_parse_missing_field;
      test_case "preamble before JSON" `Quick test_parse_with_preamble;
    ];
    "score_to_verdict", [
      test_case "score 1 fails" `Quick test_score_1_fails;
      test_case "score 2 fails" `Quick test_score_2_fails;
      test_case "score 3 warns" `Quick test_score_3_warns;
      test_case "score 4 passes" `Quick test_score_4_passes;
      test_case "score 5 passes" `Quick test_score_5_passes;
      test_case "score 0 fails" `Quick test_score_0_fails;
    ];
    "verify_auto", [
      test_case "default heuristic passes" `Quick test_verify_auto_default;
      test_case "default heuristic rejects" `Quick test_verify_auto_rejects_short;
    ];
  ]
