(** Tests for Attribution module.

    Round-trip property for every outcome variant, wire-format tagged-union
    shape, parse error paths, and smart-constructor invariants. *)

module A = Attribution

let evidence_sample : Yojson.Safe.t =
  `Assoc
    [
      ("check_id", `String "tool_limit");
      ("observed", `Int 42);
      ("threshold", `Int 30);
    ]

(* --- Outcome kind extractor for assertions --- *)

let outcome_kind = function
  | A.Passed -> "passed"
  | A.Policy_failed _ -> "policy_failed"
  | A.Transition_blocked _ -> "transition_blocked"
  | A.Partial_pass _ -> "partial_pass"

let origin_str = function A.Det -> "det" | A.NonDet -> "nondet"

(* --- Round-trip --- *)

let test_roundtrip_passed () =
  let t = A.passed ~origin:Det ~gate:"verification" ~evidence:evidence_sample in
  let json = A.to_yojson t in
  match A.of_yojson json with
  | Ok t' ->
    Alcotest.(check string) "origin" "det" (origin_str t'.origin);
    Alcotest.(check string) "gate" t.gate t'.gate;
    Alcotest.(check string) "outcome kind" "passed" (outcome_kind t'.outcome)
  | Error msg -> Alcotest.fail ("roundtrip passed failed: " ^ msg)

let test_roundtrip_policy_failed () =
  let t =
    A.policy_failed ~origin:Det ~gate:"exec_policy" ~evidence:`Null
      ~reason:"command not allowed"
  in
  let json = A.to_yojson t in
  match A.of_yojson json with
  | Ok t' ->
    (match t'.outcome with
     | Policy_failed { reason } ->
       Alcotest.(check string) "reason" "command not allowed" reason
     | other ->
       Alcotest.fail ("expected Policy_failed, got " ^ outcome_kind other))
  | Error msg -> Alcotest.fail ("roundtrip policy_failed: " ^ msg)

let test_roundtrip_transition_blocked () =
  let t =
    A.transition_blocked ~origin:Det ~gate:"keeper_fsm"
      ~evidence:evidence_sample ~from_state:"Idle" ~to_state:"Running"
      ~reason:"context overflow"
  in
  let json = A.to_yojson t in
  match A.of_yojson json with
  | Ok t' ->
    (match t'.outcome with
     | Transition_blocked { from_state; to_state; reason } ->
       Alcotest.(check string) "from_state" "Idle" from_state;
       Alcotest.(check string) "to_state" "Running" to_state;
       Alcotest.(check string) "reason" "context overflow" reason
     | other ->
       Alcotest.fail
         ("expected Transition_blocked, got " ^ outcome_kind other))
  | Error msg -> Alcotest.fail ("roundtrip transition_blocked: " ^ msg)

let test_roundtrip_partial_pass_nondet () =
  let t =
    A.partial_pass ~origin:NonDet ~gate:"verification" ~evidence:evidence_sample
      ~score:0.85 ~rationale:"output partially matches spec"
  in
  let json = A.to_yojson t in
  match A.of_yojson json with
  | Ok t' ->
    Alcotest.(check string) "origin" "nondet" (origin_str t'.origin);
    (match t'.outcome with
     | Partial_pass { score; rationale } ->
       Alcotest.(check (float 0.0001)) "score" 0.85 score;
       Alcotest.(check string) "rationale" "output partially matches spec"
         rationale
     | other ->
       Alcotest.fail ("expected Partial_pass, got " ^ outcome_kind other))
  | Error msg -> Alcotest.fail ("roundtrip partial_pass: " ^ msg)

(* --- Wire format shape --- *)

let outcome_kind_in_json json =
  match json with
  | `Assoc fields -> (
    match List.assoc_opt "kind" fields with
    | Some (`String s) -> s
    | _ -> "<no kind>")
  | _ -> "<not object>"

let test_wire_format_tagged_union () =
  let cases =
    [
      (A.passed ~origin:Det ~gate:"x" ~evidence:`Null, "passed");
      ( A.policy_failed ~origin:Det ~gate:"x" ~evidence:`Null ~reason:"r",
        "policy_failed" );
      ( A.transition_blocked ~origin:Det ~gate:"x" ~evidence:`Null
          ~from_state:"A" ~to_state:"B" ~reason:"r",
        "transition_blocked" );
      ( A.partial_pass ~origin:Det ~gate:"x" ~evidence:`Null ~score:0.5
          ~rationale:"r",
        "partial_pass" );
    ]
  in
  List.iter
    (fun (t, expected_kind) ->
      let json = A.to_yojson t in
      match json with
      | `Assoc fields -> (
        match List.assoc_opt "outcome" fields with
        | Some oj ->
          Alcotest.(check string)
            ("outcome.kind for " ^ expected_kind)
            expected_kind (outcome_kind_in_json oj)
        | None -> Alcotest.fail "missing outcome field")
      | _ -> Alcotest.fail "to_yojson must produce an object")
    cases

let test_wire_format_toplevel_shape () =
  let t = A.passed ~origin:Det ~gate:"x" ~evidence:`Null in
  match A.to_yojson t with
  | `Assoc fields ->
    List.iter
      (fun key ->
        Alcotest.(check bool)
          (key ^ " present") true
          (List.mem_assoc key fields))
      [ "origin"; "gate"; "evidence"; "outcome" ];
    (* No leftover top-level fields from the old product-type design. *)
    List.iter
      (fun key ->
        Alcotest.(check bool)
          (key ^ " absent (sum type, not product)") false
          (List.mem_assoc key fields))
      [ "verdict"; "reason"; "blocked_from"; "blocked_to"; "rationale" ]
  | _ -> Alcotest.fail "to_yojson must produce an object"

(* --- Parse errors --- *)

let expect_error name json =
  match A.of_yojson json with
  | Ok _ -> Alcotest.fail ("expected error for " ^ name)
  | Error _ -> ()

let test_parse_missing_origin () =
  expect_error "missing origin"
    (`Assoc
       [
         ("gate", `String "x");
         ("evidence", `Null);
         ("outcome", `Assoc [ ("kind", `String "passed") ]);
       ])

let test_parse_unknown_origin () =
  match
    A.of_yojson
      (`Assoc
         [
           ("origin", `String "maybe");
           ("gate", `String "x");
           ("evidence", `Null);
           ("outcome", `Assoc [ ("kind", `String "passed") ]);
         ])
  with
  | Ok _ -> Alcotest.fail "expected error"
  | Error msg ->
    Alcotest.(check bool)
      "error mentions bad input" true
      (Astring.String.is_infix ~affix:"maybe" msg)

let test_parse_unknown_outcome_kind () =
  match
    A.of_yojson
      (`Assoc
         [
           ("origin", `String "det");
           ("gate", `String "x");
           ("evidence", `Null);
           ("outcome", `Assoc [ ("kind", `String "shrug") ]);
         ])
  with
  | Ok _ -> Alcotest.fail "expected error"
  | Error msg ->
    Alcotest.(check bool)
      "error mentions bad kind" true
      (Astring.String.is_infix ~affix:"shrug" msg)

let test_parse_policy_failed_missing_reason () =
  expect_error "policy_failed missing reason"
    (`Assoc
       [
         ("origin", `String "det");
         ("gate", `String "x");
         ("evidence", `Null);
         ("outcome", `Assoc [ ("kind", `String "policy_failed") ]);
       ])

let test_parse_transition_blocked_missing_field () =
  (* Missing to_state. *)
  expect_error "transition_blocked missing to_state"
    (`Assoc
       [
         ("origin", `String "det");
         ("gate", `String "x");
         ("evidence", `Null);
         ( "outcome",
           `Assoc
             [
               ("kind", `String "transition_blocked");
               ("from_state", `String "A");
               ("reason", `String "r");
             ] );
       ])

let test_parse_partial_pass_wrong_type () =
  (* score as string instead of number. *)
  expect_error "partial_pass score wrong type"
    (`Assoc
       [
         ("origin", `String "det");
         ("gate", `String "x");
         ("evidence", `Null);
         ( "outcome",
           `Assoc
             [
               ("kind", `String "partial_pass");
               ("score", `String "high");
               ("rationale", `String "r");
             ] );
       ])

let missing_evidence_json =
  `Assoc
    [
      ("origin", `String "det");
      ("gate", `String "x");
      ("outcome", `Assoc [ ("kind", `String "passed") ]);
    ]

let test_parse_missing_evidence_rejects () =
  match A.of_yojson missing_evidence_json with
  | Ok _ -> Alcotest.fail "current decoder must reject missing evidence"
  | Error msg ->
    Alcotest.(check string) "error" "missing required field: evidence" msg

let test_parse_legacy_missing_evidence_defaults_null () =
  match A.of_legacy_yojson missing_evidence_json with
  | Ok t -> Alcotest.(check bool) "evidence=Null" true (t.evidence = `Null)
  | Error msg -> Alcotest.fail ("legacy decoder should tolerate missing evidence: " ^ msg)

let test_parse_non_object () =
  expect_error "non-object" (`String "nope")

(* --- Show --- *)

let test_show_elides_long_fields () =
  let t =
    A.policy_failed ~origin:NonDet ~gate:"verification"
      ~evidence:(`String "very long evidence blob that should not appear")
      ~reason:"also long rationale text"
  in
  let s = A.show t in
  Alcotest.(check bool)
    "no evidence in show" false
    (Astring.String.is_infix ~affix:"very long evidence" s);
  Alcotest.(check bool)
    "no reason text in show" false
    (Astring.String.is_infix ~affix:"also long rationale" s);
  Alcotest.(check bool)
    "has gate" true
    (Astring.String.is_infix ~affix:"verification" s);
  Alcotest.(check bool)
    "has outcome kind" true
    (Astring.String.is_infix ~affix:"policy_failed" s)

(* --- Entry --- *)

let () =
  Alcotest.run "attribution"
    [
      ( "roundtrip",
        [
          Alcotest.test_case "passed" `Quick test_roundtrip_passed;
          Alcotest.test_case "policy_failed" `Quick
            test_roundtrip_policy_failed;
          Alcotest.test_case "transition_blocked" `Quick
            test_roundtrip_transition_blocked;
          Alcotest.test_case "partial_pass nondet" `Quick
            test_roundtrip_partial_pass_nondet;
        ] );
      ( "wire format",
        [
          Alcotest.test_case "tagged union kind" `Quick
            test_wire_format_tagged_union;
          Alcotest.test_case "top-level shape (no leftover flat fields)"
            `Quick test_wire_format_toplevel_shape;
        ] );
      ( "parse errors",
        [
          Alcotest.test_case "missing origin" `Quick test_parse_missing_origin;
          Alcotest.test_case "unknown origin" `Quick test_parse_unknown_origin;
          Alcotest.test_case "unknown outcome kind" `Quick
            test_parse_unknown_outcome_kind;
          Alcotest.test_case "policy_failed missing reason" `Quick
            test_parse_policy_failed_missing_reason;
          Alcotest.test_case "transition_blocked missing field" `Quick
            test_parse_transition_blocked_missing_field;
          Alcotest.test_case "partial_pass wrong type" `Quick
            test_parse_partial_pass_wrong_type;
          Alcotest.test_case "missing evidence rejects" `Quick
            test_parse_missing_evidence_rejects;
          Alcotest.test_case "legacy missing evidence defaults to null" `Quick
            test_parse_legacy_missing_evidence_defaults_null;
          Alcotest.test_case "non-object input" `Quick test_parse_non_object;
        ] );
      ( "show",
        [
          Alcotest.test_case "elides long fields" `Quick
            test_show_elides_long_fields;
        ] );
    ]
