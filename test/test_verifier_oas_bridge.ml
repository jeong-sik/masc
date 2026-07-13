(** test_verifier_oas_bridge — Pure tests for Verifier_oas parsing.

    @since OAS Integration Phase 2 *)

open Masc

module Core = Verifier_core

let test_parse_response_text_accepts_strict_json () =
  let raw =
    {|{"verdict":"WARN","reason":"minor issue","evidence":[]}|}
  in
  match Verifier_oas.For_testing.parse_verdict_from_response_text raw with
  | Ok (Core.Warn reason) ->
    Alcotest.(check string) "reason" "minor issue" reason
  | Ok other ->
    Alcotest.failf
      "expected WARN, got %s"
      (Core.verdict_to_string other)
  | Error msg -> Alcotest.fail ("strict JSON response rejected: " ^ msg)

let test_parse_response_text_rejects_plain_verdict () =
  match Verifier_oas.For_testing.parse_verdict_from_response_text "PASS" with
  | Error _ -> ()
  | Ok verdict ->
    Alcotest.failf
      "plain verdict should be rejected, got %s"
      (Core.verdict_to_string verdict)

let test_parse_response_text_rejects_non_schema_enum () =
  match
    Verifier_oas.For_testing.parse_verdict_from_response_text
      {|{"verdict":"pass","reason":null,"evidence":[]}|}
  with
  | Error _ -> ()
  | Ok verdict ->
    Alcotest.failf
      "verdict outside the declared enum should be rejected, got %s"
      (Core.verdict_to_string verdict)

(* ================================================================ *)
(* Test Suite                                                        *)
(* ================================================================ *)

let () =
  Alcotest.run "verifier_oas_bridge" [
    ("structured response", [
      Alcotest.test_case "response text accepts strict JSON" `Quick
        test_parse_response_text_accepts_strict_json;
      Alcotest.test_case "response text rejects plain verdict" `Quick
        test_parse_response_text_rejects_plain_verdict;
      Alcotest.test_case "response text rejects non-schema enum" `Quick
        test_parse_response_text_rejects_non_schema_enum;
    ]);
  ]
