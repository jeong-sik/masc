(** Tests for Attribution module serialization and smart constructors. *)

module A = Attribution

let evidence_sample : Yojson.Safe.t =
  `Assoc
    [
      ("check_id", `String "tool_limit");
      ("observed", `Int 42);
      ("threshold", `Int 30);
    ]

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
    (* Outcome-specific fields remain inside the tagged sum. *)
    List.iter
      (fun key ->
        Alcotest.(check bool)
          (key ^ " absent (sum type, not product)") false
          (List.mem_assoc key fields))
      [ "verdict"; "reason"; "blocked_from"; "blocked_to"; "rationale" ]
  | _ -> Alcotest.fail "to_yojson must produce an object"

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
      ( "wire format",
        [
          Alcotest.test_case "tagged union kind" `Quick
            test_wire_format_tagged_union;
          Alcotest.test_case "top-level shape (no leftover flat fields)"
            `Quick test_wire_format_toplevel_shape;
        ] );
      ( "show",
        [
          Alcotest.test_case "elides long fields" `Quick
            test_show_elides_long_fields;
        ] );
    ]
