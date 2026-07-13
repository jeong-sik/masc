(** test_verifier_core_grounding — RFC-0258 P1 additive grounding.

    These tests pin the narrow contract: the public [verdict] variant stays
    unchanged, verdict-only JSON parsing accepts the structured payload, and
    the grounded parser refuses ungrounded blocking verdicts. *)

module VC = Masc.Verifier_core

let evidence ?line ?(path = "lib/foo.ml") ?(quote = "let x = 1") () :
    VC.grounded_ref =
  { path; line; quote }

let json ?reason ?evidence_items verdict =
  let fields =
    [ ("verdict", `String verdict) ]
    @ (match reason with None -> [] | Some s -> [ ("reason", `String s) ])
    @
    match evidence_items with
    | None -> []
    | Some items -> [ ("evidence", `List items) ]
  in
  `Assoc fields

let evidence_json ?line ?(path = "lib/foo.ml") ?(quote = "let x = 1") () =
  let fields =
    [ ("path", `String path); ("quote", `String quote) ]
    @ (match line with None -> [] | Some n -> [ ("line", `Int n) ])
  in
  `Assoc fields

let test_grounded_of_pass_allows_no_evidence () =
  match VC.grounded_of VC.Pass [] with
  | Ok grounded ->
    Alcotest.(check bool) "pass verdict" true (grounded.verdict = VC.Pass);
    Alcotest.(check int) "pass evidence ignored" 0 (List.length grounded.evidence)
  | Error msg -> Alcotest.fail msg

let test_grounded_of_fail_requires_evidence () =
  match VC.grounded_of (VC.Fail "bad") [] with
  | Error msg ->
    Alcotest.(check bool) "mentions evidence" true (String.length msg > 0)
  | Ok _ -> Alcotest.fail "expected ungrounded FAIL to be refused"

let test_grounded_of_warn_requires_evidence () =
  match VC.grounded_of (VC.Warn "concern") [] with
  | Error msg ->
    Alcotest.(check bool) "mentions evidence" true (String.length msg > 0)
  | Ok _ -> Alcotest.fail "expected ungrounded WARN to be refused"

let test_grounded_of_fail_accepts_valid_evidence () =
  match VC.grounded_of (VC.Fail "bad") [ evidence ~line:7 () ] with
  | Ok grounded ->
    Alcotest.(check int) "one evidence" 1 (List.length grounded.evidence);
    let first = List.hd grounded.evidence in
    Alcotest.(check (option int)) "line preserved" (Some 7) first.line
  | Error msg -> Alcotest.fail msg

let test_verdict_parser_accepts_optional_evidence () =
  let payload =
    json ~reason:"bad" ~evidence_items:[ evidence_json ~line:3 () ] "FAIL"
  in
  match VC.parse_verdict_from_json payload with
  | Ok (VC.Fail reason) -> Alcotest.(check string) "reason" "bad" reason
  | Ok other ->
    Alcotest.failf "expected Fail, got %s" (VC.verdict_to_string other)
  | Error msg -> Alcotest.fail msg

let test_grounded_parser_round_trips_evidence () =
  let payload =
    json ~reason:"bad"
      ~evidence_items:[ evidence_json ~line:3 ~path:"lib/foo.ml" ~quote:"let x = 1" () ]
      "FAIL"
  in
  match VC.parse_grounded_verdict_from_json payload with
  | Ok grounded ->
    Alcotest.(check int) "one evidence" 1 (List.length grounded.evidence);
    let first = List.hd grounded.evidence in
    Alcotest.(check string) "path" "lib/foo.ml" first.path;
    Alcotest.(check (option int)) "line" (Some 3) first.line;
    Alcotest.(check string) "quote" "let x = 1" first.quote
  | Error msg -> Alcotest.fail msg

let test_grounded_parser_ignores_pass_evidence () =
  let payload =
    json ~evidence_items:[ `String "not an evidence object" ] "PASS"
  in
  match VC.parse_grounded_verdict_from_json payload with
  | Ok grounded ->
    Alcotest.(check bool) "pass verdict" true (grounded.verdict = VC.Pass);
    Alcotest.(check int) "pass evidence ignored" 0 (List.length grounded.evidence)
  | Error msg -> Alcotest.fail msg

let test_grounded_parser_refuses_empty_fail () =
  match VC.parse_grounded_verdict_from_json (json ~reason:"bad" "FAIL") with
  | Error msg ->
    Alcotest.(check bool) "mentions evidence" true (String.length msg > 0)
  | Ok _ -> Alcotest.fail "expected ungrounded FAIL to be refused"

let test_grounded_parser_rejects_bad_line () =
  let payload =
    json ~reason:"bad" ~evidence_items:[ evidence_json ~line:0 () ] "FAIL"
  in
  match VC.parse_grounded_verdict_from_json payload with
  | Error msg ->
    Alcotest.(check bool) "mentions line" true
      (String.contains msg 'l')
  | Ok _ -> Alcotest.fail "expected line 0 to be rejected"

let test_grounded_verdict_serializes_evidence () =
  match VC.grounded_of (VC.Fail "bad") [ evidence ~line:9 ~quote:"let bad = true" () ] with
  | Error msg -> Alcotest.fail msg
  | Ok grounded ->
    let open Yojson.Safe.Util in
    let json = VC.grounded_verdict_to_yojson grounded in
    Alcotest.(check string) "verdict" "FAIL" (json |> member "verdict" |> to_string);
    Alcotest.(check string) "reason" "bad" (json |> member "reason" |> to_string);
    let first = json |> member "evidence" |> to_list |> List.hd in
    Alcotest.(check string) "path" "lib/foo.ml" (first |> member "path" |> to_string);
    Alcotest.(check int) "line" 9 (first |> member "line" |> to_int);
    Alcotest.(check string) "quote" "let bad = true" (first |> member "quote" |> to_string)

let test_report_schema_keeps_verdict_enum_and_adds_evidence () =
  let schema = VC.report_verdict_schema.input_schema in
  let open Yojson.Safe.Util in
  let props = schema |> member "properties" in
  let enum =
    props |> member "verdict" |> member "enum" |> to_list
    |> List.map to_string
  in
  Alcotest.(check (list string)) "verdict enum unchanged"
    [ "PASS"; "WARN"; "FAIL" ] enum;
  Alcotest.(check string) "evidence is array"
    "array"
    (props |> member "evidence" |> member "type" |> to_string)

let () =
  Alcotest.run "verifier_core_grounding"
    [
      ( "grounded_of",
        [
          Alcotest.test_case "Pass allows no evidence" `Quick
            test_grounded_of_pass_allows_no_evidence;
          Alcotest.test_case "Fail requires evidence" `Quick
            test_grounded_of_fail_requires_evidence;
          Alcotest.test_case "Warn requires evidence" `Quick
            test_grounded_of_warn_requires_evidence;
          Alcotest.test_case "Fail accepts evidence" `Quick
            test_grounded_of_fail_accepts_valid_evidence;
        ] );
      ( "json",
        [
          Alcotest.test_case "verdict parser accepts evidence" `Quick
            test_verdict_parser_accepts_optional_evidence;
          Alcotest.test_case "grounded parser round trips evidence" `Quick
            test_grounded_parser_round_trips_evidence;
          Alcotest.test_case "grounded parser ignores Pass evidence" `Quick
            test_grounded_parser_ignores_pass_evidence;
          Alcotest.test_case "grounded parser refuses empty Fail" `Quick
            test_grounded_parser_refuses_empty_fail;
          Alcotest.test_case "grounded parser rejects bad line" `Quick
            test_grounded_parser_rejects_bad_line;
          Alcotest.test_case "grounded verdict serializes evidence" `Quick
            test_grounded_verdict_serializes_evidence;
          Alcotest.test_case "schema keeps enum and adds evidence" `Quick
            test_report_schema_keeps_verdict_enum_and_adds_evidence;
        ] );
    ]
