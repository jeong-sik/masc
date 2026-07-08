(** Ratchet: [Task.Anti_rationalization.review] treats an empty evaluator
    response as an invalid verdict and rejects via [Format_reject].

    The runtime log on 2026-06-28 showed repeated
    "evaluator returned empty text (approving by liveness)" entries. That
    path silently accepted task completion without a reviewer verdict. The
    parser still preserves the public string error for callers, but
    production routing uses the typed parse error so the reject branch does
    not depend on matching an error string. *)

module AR = Masc.Task.Anti_rationalization

(* The evaluator-policy tests below exercise the Gate 3 LLM-reviewer path, so
   the request must clear the upstream evidence gate (Gate 0). #23738 turned
   Gate 0 into a real reject for empty evidence_refs; supplying a concrete ref
   keeps these tests aimed at the evaluator behaviour they assert rather than
   short-circuiting on the evidence gate. Gate-0 scoping itself is covered by
   the [make_request_no_evidence] tests. *)
let make_request () : AR.review_request =
  {
    agent_name = "test-keeper-empty-reject";
    task_title = "finish concrete task";
    task_description = "Implement and verify a concrete task.";
    completion_notes = "Implemented the change and verified the focused test.";
    task_id = "test-task-empty-reject";
    evidence_refs = [ "local:git commit a1b2c3d" ];
  }

(* Same request with no evidence — used only to pin Gate 0 scoping. *)
let make_request_no_evidence () : AR.review_request =
  { (make_request ()) with evidence_refs = [] }

let with_reviewer reviewer f =
  let saved = Atomic.get AR.run_llm_reviewer_fn in
  Fun.protect
    ~finally:(fun () -> Atomic.set AR.run_llm_reviewer_fn saved)
    (fun () ->
      Atomic.set AR.run_llm_reviewer_fn reviewer;
      f ())

let contains_substring haystack needle =
  let needle_len = String.length needle in
  let haystack_len = String.length haystack in
  let rec loop idx =
    if needle_len = 0
    then true
    else if idx + needle_len > haystack_len
    then false
    else if String.sub haystack idx needle_len = needle
    then true
    else loop (idx + 1)
  in
  loop 0

let test_empty_verdict_emits_typed_error () =
  match AR.parse_verdict_typed "" with
  | Error AR.Empty_review_output -> ()
  | Error err ->
    Alcotest.failf
      "parse_verdict_typed \"\" returned %s"
      (AR.verdict_parse_error_to_string err)
  | Ok _ -> Alcotest.fail "parse_verdict_typed \"\" should return Error"

let test_empty_verdict_preserves_public_string_error () =
  match AR.parse_verdict "" with
  | Error msg ->
      Alcotest.(check string)
        "empty text gives canonical 'empty review output' error"
        "empty review output" msg
  | Ok _ ->
      Alcotest.fail "parse_verdict \"\" should return Error"

let test_whitespace_only_verdict_also_empty () =
  match AR.parse_verdict_typed "   \n\t  " with
  | Error AR.Empty_review_output -> ()
  | Error err ->
    Alcotest.failf
      "whitespace-only text returned %s"
      (AR.verdict_parse_error_to_string err)
  | Ok _ ->
      Alcotest.fail "parse_verdict of whitespace should return Error"

let test_review_rejects_empty_evaluator_output () =
  with_reviewer
    (fun ?sw:_ ~evaluator_runtime:_ ~prompt:_ ~report_tool_schema:_ () ->
      Ok (None, ""))
    (fun () ->
      let result =
        AR.review ~evaluator_runtime:"test-empty-evaluator" (make_request ())
      in
      Alcotest.(check string)
        "gate" "format_reject" (AR.gate_to_string result.AR.gate);
      Alcotest.(check (option string))
        "fallback reason"
        (Some "empty review output")
        result.AR.fallback_reason;
      match result.AR.verdict with
      | AR.Reject reason ->
        Alcotest.(check string)
          "reject reason"
          "review format unrecognized: empty review output"
          reason
      | AR.Approve ->
        Alcotest.fail
          "empty evaluator output must not approve by liveness")

let test_review_accepts_strict_json_evaluator_response () =
  with_reviewer
    (fun ?sw:_ ~evaluator_runtime:_ ~prompt:_ ~report_tool_schema:_ () ->
      Ok (None, {|{"verdict":"APPROVE"}|}))
    (fun () ->
      let result =
        AR.review ~evaluator_runtime:"test-json-evaluator" (make_request ())
      in
      Alcotest.(check string)
        "gate" "llm_text_fallback" (AR.gate_to_string result.AR.gate);
      match result.AR.verdict with
      | AR.Approve -> ()
      | AR.Reject reason ->
        Alcotest.failf "strict JSON APPROVE should pass, rejected: %s" reason)

let check_review_rejects_evaluator_text ~label ~text ~reason_substring =
  with_reviewer
    (fun ?sw:_ ~evaluator_runtime:_ ~prompt:_ ~report_tool_schema:_ () ->
      Ok (None, text))
    (fun () ->
      let result =
        AR.review ~evaluator_runtime:("test-" ^ label) (make_request ())
      in
      Alcotest.(check string)
        "gate" "format_reject" (AR.gate_to_string result.AR.gate);
      (match result.AR.fallback_reason with
       | Some reason ->
         Alcotest.(check bool)
           "fallback reason names strict JSON requirement"
           true
           (contains_substring reason reason_substring)
       | None -> Alcotest.fail "format reject should include a fallback reason");
      match result.AR.verdict with
      | AR.Reject _ -> ()
      | AR.Approve -> Alcotest.failf "%s evaluator output must not approve" label)

let test_review_rejects_prose_evaluator_response () =
  check_review_rejects_evaluator_text ~label:"prose-evaluator" ~text:"APPROVE"
    ~reason_substring:"strict verdict JSON"

let test_review_rejects_malformed_json_evaluator_response () =
  check_review_rejects_evaluator_text ~label:"malformed-json-evaluator"
    ~text:{|{"verdict":"APPROVE"|}
    ~reason_substring:"strict verdict JSON"

let test_review_rejects_non_object_json_evaluator_response () =
  check_review_rejects_evaluator_text ~label:"array-json-evaluator"
    ~text:{|[{"verdict":"APPROVE"}]|}
    ~reason_substring:"review verdict"

(* Regression (#23738): Gate 0 must be scoped to verification-required tasks.
   A non-verification-required completion (task_requires_verification=false,
   threaded as ~requires_evidence:false) with empty evidence_refs must NOT be
   rejected by the evidence gate — it falls through to the evaluator, which
   here approves. Before the scoping fix, Gate 0 rejected unconditionally and
   pre-empted the RFC-0323 G-2 workspace gate. *)
let test_gate0_skipped_when_not_verification_required () =
  with_reviewer
    (fun ?sw:_ ~evaluator_runtime:_ ~prompt:_ ~report_tool_schema:_ () ->
      Ok (None, {|{"verdict":"APPROVE"}|}))
    (fun () ->
      let result =
        AR.review ~evaluator_runtime:"test-scope-not-required"
          ~requires_evidence:false (make_request_no_evidence ())
      in
      Alcotest.(check bool)
        "gate is not the evidence gate"
        true
        (not (String.equal (AR.gate_to_string result.AR.gate) "evidence"));
      match result.AR.verdict with
      | AR.Approve -> ()
      | AR.Reject reason ->
        Alcotest.failf
          "non-verification-required empty-evidence completion must reach the \
           evaluator and approve, rejected: %s"
          reason)

(* Complement: when the task IS verification-required (~requires_evidence:true,
   the default), empty evidence still fails closed at Gate 0. *)
let test_gate0_fires_when_verification_required () =
  with_reviewer
    (fun ?sw:_ ~evaluator_runtime:_ ~prompt:_ ~report_tool_schema:_ () ->
      Ok (None, {|{"verdict":"APPROVE"}|}))
    (fun () ->
      let result =
        AR.review ~evaluator_runtime:"test-scope-required"
          ~requires_evidence:true (make_request_no_evidence ())
      in
      Alcotest.(check string)
        "gate" "evidence" (AR.gate_to_string result.AR.gate);
      match result.AR.verdict with
      | AR.Reject reason ->
        Alcotest.(check string)
          "reject reason" "no evidence references supplied" reason
      | AR.Approve ->
        Alcotest.fail
          "verification-required empty-evidence completion must fail closed at \
           Gate 0")

let () =
  Alcotest.run
    "anti_rationalization_empty_reject"
    [
      ( "parse_verdict empty precondition",
        [
          Alcotest.test_case
            "typed empty error"
            `Quick
            test_empty_verdict_emits_typed_error;
          Alcotest.test_case
            "public string error"
            `Quick
            test_empty_verdict_preserves_public_string_error;
          Alcotest.test_case
            "whitespace-only"
            `Quick
            test_whitespace_only_verdict_also_empty;
        ] );
      ( "review policy",
        [
          Alcotest.test_case
            "empty evaluator output rejects"
            `Quick
            test_review_rejects_empty_evaluator_output;
          Alcotest.test_case
            "strict JSON evaluator response passes"
            `Quick
            test_review_accepts_strict_json_evaluator_response;
          Alcotest.test_case
            "prose evaluator response rejects"
            `Quick
            test_review_rejects_prose_evaluator_response;
          Alcotest.test_case
            "malformed JSON evaluator response rejects"
            `Quick
            test_review_rejects_malformed_json_evaluator_response;
          Alcotest.test_case
            "non-object JSON evaluator response rejects"
            `Quick
            test_review_rejects_non_object_json_evaluator_response;
        ] );
      ( "gate 0 scope (#23738 regression)",
        [
          Alcotest.test_case
            "empty evidence skips gate 0 when not verification-required"
            `Quick
            test_gate0_skipped_when_not_verification_required;
          Alcotest.test_case
            "empty evidence fails closed when verification-required"
            `Quick
            test_gate0_fires_when_verification_required;
        ] );
    ]
