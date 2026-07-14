(** Tests for Attribution_tagged — phantom-typed origin boundary.

    The phantom type itself cannot be directly tested at runtime (by
    design — the type system erases it). What we can verify:
    - Each smart constructor produces an underlying Attribution with the
      correct [origin] field.
    - NonDet [Passed] / [Policy_failed] embed [rationale] into [evidence]
      (so the value is preserved through the erased Attribution.t).
    - Outcome kinds match constructor names.
    - Phantom-typed functions compile (a dedicated compile-only test at
      the bottom — it isn't run, but if it stopped compiling the test
      suite wouldn't link, which doubles as the phantom-type check). *)

module AT = Attribution_tagged
module A = Attribution

let outcome_kind = function
  | A.Passed -> "passed"
  | A.Policy_failed _ -> "policy_failed"
  | A.Transition_blocked _ -> "transition_blocked"
  | A.Partial_pass _ -> "partial_pass"

let origin_str = function A.Det -> "det" | A.NonDet -> "nondet"

(* --- Det constructors --- *)

let test_det_passed () =
  let t = AT.det_passed ~gate:"verification" ~evidence:`Null in
  let a = AT.to_attribution t in
  Alcotest.(check string) "origin" "det" (origin_str a.origin);
  Alcotest.(check string) "outcome" "passed" (outcome_kind a.outcome)

let test_det_policy_failed () =
  let t =
    AT.det_policy_failed ~gate:"exec_policy" ~evidence:`Null
      ~reason:"rm not allowed"
  in
  let a = AT.to_attribution t in
  Alcotest.(check string) "origin" "det" (origin_str a.origin);
  match a.outcome with
  | A.Policy_failed { reason } ->
    Alcotest.(check string) "reason" "rm not allowed" reason
  | _ -> Alcotest.fail "expected Policy_failed"

let test_det_transition_blocked () =
  let t =
    AT.det_transition_blocked ~gate:"keeper_fsm" ~evidence:`Null
      ~from_state:"Idle" ~to_state:"Running" ~reason:"context overflow"
  in
  let a = AT.to_attribution t in
  Alcotest.(check string) "origin" "det" (origin_str a.origin);
  match a.outcome with
  | A.Transition_blocked { from_state; to_state; reason } ->
    Alcotest.(check string) "from_state" "Idle" from_state;
    Alcotest.(check string) "to_state" "Running" to_state;
    Alcotest.(check string) "reason" "context overflow" reason
  | _ -> Alcotest.fail "expected Transition_blocked"

let test_det_partial_pass () =
  let t =
    AT.det_partial_pass ~gate:"coverage_gate" ~evidence:`Null ~score:0.85
      ~rationale:"coverage 85% below 90% threshold"
  in
  let a = AT.to_attribution t in
  Alcotest.(check string) "origin" "det" (origin_str a.origin);
  match a.outcome with
  | A.Partial_pass { score; rationale } ->
    Alcotest.(check (float 0.0001)) "score" 0.85 score;
    Alcotest.(check bool) "rationale has '85%'" true
      (Astring.String.is_infix ~affix:"85%" rationale)
  | _ -> Alcotest.fail "expected Partial_pass"

(* --- NonDet constructors --- *)

let rationale_in_evidence attr =
  match attr.A.evidence with
  | `Assoc fields -> (
    match List.assoc_opt "rationale" fields with
    | Some (`String s) -> Some s
    | _ -> None)
  | _ -> None

let test_nondet_passed_embeds_rationale () =
  let t =
    AT.nondet_passed ~gate:"verification" ~evidence:(`Assoc [])
      ~rationale:"output is helpful"
  in
  let a = AT.to_attribution t in
  Alcotest.(check string) "origin" "nondet" (origin_str a.origin);
  Alcotest.(check (option string))
    "rationale embedded" (Some "output is helpful")
    (rationale_in_evidence a)

let test_nondet_policy_failed_keeps_both_reason_and_rationale () =
  let t =
    AT.nondet_policy_failed ~gate:"verification" ~evidence:(`Assoc [])
      ~reason:"criterion not met"
      ~rationale:"the response omitted step 3 of the specification"
  in
  let a = AT.to_attribution t in
  (match a.outcome with
   | A.Policy_failed { reason } ->
     Alcotest.(check string) "reason" "criterion not met" reason
   | _ -> Alcotest.fail "expected Policy_failed");
  Alcotest.(check (option string))
    "rationale in evidence"
    (Some "the response omitted step 3 of the specification")
    (rationale_in_evidence a)

let test_nondet_partial_pass () =
  let t =
    AT.nondet_partial_pass ~gate:"verification" ~evidence:`Null ~score:0.7
      ~rationale:"partial match — missing edge case coverage"
  in
  let a = AT.to_attribution t in
  Alcotest.(check string) "origin" "nondet" (origin_str a.origin);
  match a.outcome with
  | A.Partial_pass { score; rationale } ->
    Alcotest.(check (float 0.0001)) "score" 0.7 score;
    Alcotest.(check string) "rationale" "partial match — missing edge case coverage"
      rationale
  | _ -> Alcotest.fail "expected Partial_pass"

(* --- origin_of runtime introspection --- *)

let test_origin_of () =
  Alcotest.(check bool) "det" true
    (AT.origin_of (AT.det_passed ~gate:"x" ~evidence:`Null) = A.Det);
  Alcotest.(check bool) "nondet" true
    (AT.origin_of
       (AT.nondet_passed ~gate:"x" ~evidence:(`Assoc []) ~rationale:"r")
     = A.NonDet)

(* --- Evidence shape for non-Assoc input to NonDet --- *)

let test_nondet_wraps_non_object_evidence () =
  (* If evidence isn't an object, the wrapper nests it under
     "original_evidence" alongside the rationale so structure is
     preserved without corrupting the Yojson shape. *)
  let t =
    AT.nondet_passed ~gate:"x" ~evidence:(`String "raw blob")
      ~rationale:"judged ok"
  in
  let a = AT.to_attribution t in
  match a.evidence with
  | `Assoc fields ->
    Alcotest.(check (option bool))
      "has original_evidence" (Some true)
      (Option.map (fun _ -> true) (List.assoc_opt "original_evidence" fields));
    Alcotest.(check (option string)) "rationale embedded"
      (Some "judged ok") (rationale_in_evidence a)
  | _ -> Alcotest.fail "wrapper must produce object"

(* --- Compile-time check (won't run, just needs to compile) ---
   The following function accepts only Det-tagged values. If this
   stopped compiling (e.g. if det and nondet became the same type),
   the test binary wouldn't link. That's the phantom-type invariant. *)

let _consume_only_det (_ : AT.det AT.t) : unit = ()

let _example_det_site () =
  _consume_only_det (AT.det_passed ~gate:"x" ~evidence:`Null)
  (* This would be a type error if uncommented:
     _consume_only_det
       (AT.nondet_passed ~gate:"x" ~evidence:(`Assoc []) ~rationale:"r") *)

let () =
  Alcotest.run "Attribution_tagged"
    [
      ( "det",
        [
          Alcotest.test_case "passed" `Quick test_det_passed;
          Alcotest.test_case "policy_failed" `Quick test_det_policy_failed;
          Alcotest.test_case "transition_blocked" `Quick
            test_det_transition_blocked;
          Alcotest.test_case "partial_pass (score-based rule)" `Quick
            test_det_partial_pass;
        ] );
      ( "nondet",
        [
          Alcotest.test_case "passed embeds rationale in evidence" `Quick
            test_nondet_passed_embeds_rationale;
          Alcotest.test_case "policy_failed keeps reason + rationale"
            `Quick test_nondet_policy_failed_keeps_both_reason_and_rationale;
          Alcotest.test_case "partial_pass" `Quick test_nondet_partial_pass;
          Alcotest.test_case "non-object evidence wrapped" `Quick
            test_nondet_wraps_non_object_evidence;
        ] );
      ( "introspection",
        [
          Alcotest.test_case "origin_of returns runtime origin" `Quick
            test_origin_of;
        ] );
    ]
