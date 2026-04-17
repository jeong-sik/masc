(** Tests for Attribution module.

    Round-trip property for every variant combination, boundary cases
    for missing fields, and smart constructor invariants. *)

module A = Masc_mcp.Attribution

let evidence_sample : Yojson.Safe.t =
  `Assoc [
    ("check_id", `String "tool_limit");
    ("observed", `Int 42);
    ("threshold", `Int 30);
  ]

(* --- Round-trip --- *)

let test_roundtrip_pass () =
  let t = A.pass ~origin:Det ~gate:"cdal_verdict" ~evidence:evidence_sample in
  let json = A.to_yojson t in
  match A.of_yojson json with
  | Ok t' ->
    Alcotest.(check string) "origin" "det" (match t'.origin with Det -> "det" | NonDet -> "nondet");
    Alcotest.(check string) "gate" t.gate t'.gate;
    Alcotest.(check string) "verdict" "pass" (match t'.verdict with Pass -> "pass" | Fail -> "fail" | Partial -> "partial");
    Alcotest.(check (option string)) "blocked_from" None t'.blocked_from;
    Alcotest.(check (option string)) "rationale" None t'.rationale
  | Error msg -> Alcotest.fail ("roundtrip pass failed: " ^ msg)

let test_roundtrip_fail_with_block () =
  let t = A.fail ~origin:Det ~gate:"keeper_fsm" ~evidence:evidence_sample
            ~blocked_from:"Idle" ~blocked_to:"Running"
            ~rationale:"context overflow" ()
  in
  let json = A.to_yojson t in
  match A.of_yojson json with
  | Ok t' ->
    Alcotest.(check (option string)) "blocked_from" (Some "Idle") t'.blocked_from;
    Alcotest.(check (option string)) "blocked_to" (Some "Running") t'.blocked_to;
    Alcotest.(check (option string)) "rationale" (Some "context overflow") t'.rationale
  | Error msg -> Alcotest.fail ("roundtrip fail failed: " ^ msg)

let test_roundtrip_partial_nondet () =
  let t = A.partial ~origin:NonDet ~gate:"verification" ~evidence:evidence_sample
            ~rationale:"output partially matches spec" ()
  in
  let json = A.to_yojson t in
  match A.of_yojson json with
  | Ok t' ->
    Alcotest.(check string) "origin" "nondet" (match t'.origin with Det -> "det" | NonDet -> "nondet");
    Alcotest.(check string) "verdict" "partial" (match t'.verdict with Pass -> "pass" | Fail -> "fail" | Partial -> "partial");
    Alcotest.(check (option string)) "rationale" (Some "output partially matches spec") t'.rationale
  | Error msg -> Alcotest.fail ("roundtrip partial failed: " ^ msg)

(* --- Wire format shape --- *)

let test_wire_format_omits_none_fields () =
  let t = A.pass ~origin:Det ~gate:"accountability" ~evidence:`Null in
  let json = A.to_yojson t in
  match json with
  | `Assoc fields ->
    Alcotest.(check bool) "no blocked_from" false (List.mem_assoc "blocked_from" fields);
    Alcotest.(check bool) "no blocked_to" false (List.mem_assoc "blocked_to" fields);
    Alcotest.(check bool) "no rationale" false (List.mem_assoc "rationale" fields);
    Alcotest.(check bool) "has origin" true (List.mem_assoc "origin" fields);
    Alcotest.(check bool) "has gate" true (List.mem_assoc "gate" fields);
    Alcotest.(check bool) "has verdict" true (List.mem_assoc "verdict" fields);
    Alcotest.(check bool) "has evidence" true (List.mem_assoc "evidence" fields)
  | _ -> Alcotest.fail "to_yojson must produce an object"

(* --- Error paths --- *)

let test_parse_rejects_missing_origin () =
  let json = `Assoc [("gate", `String "x"); ("verdict", `String "pass")] in
  match A.of_yojson json with
  | Ok _ -> Alcotest.fail "expected error on missing origin"
  | Error _ -> ()

let test_parse_rejects_unknown_origin () =
  let json = `Assoc [
    ("origin", `String "maybe");
    ("gate", `String "x");
    ("verdict", `String "pass");
  ] in
  match A.of_yojson json with
  | Ok _ -> Alcotest.fail "expected error on unknown origin"
  | Error msg ->
    (* Message must mention the invalid value so operators can grep logs. *)
    Alcotest.(check bool) "error mentions bad input"
      true (Astring.String.is_infix ~affix:"maybe" msg)

let test_parse_missing_evidence_defaults_to_null () =
  let json = `Assoc [
    ("origin", `String "det");
    ("gate", `String "x");
    ("verdict", `String "pass");
  ] in
  match A.of_yojson json with
  | Ok t -> Alcotest.(check bool) "evidence=null" true (t.evidence = `Null)
  | Error msg -> Alcotest.fail ("should tolerate missing evidence: " ^ msg)

let test_parse_rejects_non_object () =
  match A.of_yojson (`String "not an object") with
  | Ok _ -> Alcotest.fail "expected error on non-object"
  | Error _ -> ()

(* --- Show --- *)

let test_show_elides_evidence () =
  let t = A.fail ~origin:NonDet ~gate:"verification"
            ~evidence:(`String "very long evidence blob that should not appear")
            ~rationale:"also long rationale"
            ()
  in
  let s = A.show t in
  Alcotest.(check bool) "no evidence in show" false
    (Astring.String.is_infix ~affix:"very long evidence" s);
  Alcotest.(check bool) "no rationale in show" false
    (Astring.String.is_infix ~affix:"also long rationale" s);
  Alcotest.(check bool) "has gate" true
    (Astring.String.is_infix ~affix:"verification" s)

(* --- Entry --- *)

let () =
  Alcotest.run "attribution" [
    ("roundtrip", [
      Alcotest.test_case "pass"                       `Quick test_roundtrip_pass;
      Alcotest.test_case "fail with block info"       `Quick test_roundtrip_fail_with_block;
      Alcotest.test_case "partial nondet"             `Quick test_roundtrip_partial_nondet;
    ]);
    ("wire format", [
      Alcotest.test_case "omits None fields"          `Quick test_wire_format_omits_none_fields;
    ]);
    ("parse errors", [
      Alcotest.test_case "missing origin"             `Quick test_parse_rejects_missing_origin;
      Alcotest.test_case "unknown origin value"       `Quick test_parse_rejects_unknown_origin;
      Alcotest.test_case "missing evidence defaults"  `Quick test_parse_missing_evidence_defaults_to_null;
      Alcotest.test_case "non-object input"           `Quick test_parse_rejects_non_object;
    ]);
    ("show", [
      Alcotest.test_case "elides evidence/rationale"  `Quick test_show_elides_evidence;
    ]);
  ]
