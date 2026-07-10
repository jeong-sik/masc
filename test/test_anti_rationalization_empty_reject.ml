(** Empty evaluator response handling: fail-open by liveness (#10474).

    The runtime log on 2026-06-28 showed repeated
    "evaluator returned empty text (approving by liveness)" entries. That
    path silently accepted task completion without a reviewer verdict
    (#22573 closed it). The parser still preserves the public string error
    for callers, but production routing uses the typed parse error so the
    reject branch does not depend on matching an error string.

    2026-07-09 (24h tool-error audit): the reject stays deterministic, but
    empty output is now [Evaluator_empty] instead of [Format_reject] and the
    reason names the evaluator-side failure.

    2026-07-10 (#10474 topology deadlock fix): Empty_review_output is an
    evaluator-side failure — the keeper's notes were never reviewed. The old
    hard-reject sent keepers into an unbounded revise-notes retry loop
    (305 hits/24h) that could never succeed. Now fails-open by liveness
    when no excuse advisory is active, rejects only when there is an
    active safety-net pattern. *)

module AR = Masc.Task.Anti_rationalization

let make_request () : AR.review_request =
  {
    agent_name = "test-keeper-empty-reject";
    task_title = "finish concrete task";
    task_description = "Implement and verify a concrete task.";
    completion_notes = "Implemented the change and verified the focused test.";
    task_id = "test-task-empty-reject";
    evidence_refs = [];
  }

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

(* Test #10474 safety-net branch: notes contain an excuse pattern AND
   evaluator returns empty text → reject (not approve).  This covers the
   [excuse_advisory = Some _] branch in the Empty_review_output handler. *)
let test_empty_review_rejects_with_excuse_advisory () =
  let req : AR.review_request =
    { (make_request ()) with
      completion_notes =
        "Done. This is a pre-existing issue that was already there."
    }
  in
  with_reviewer
    (fun ?sw:_ ~evaluator_runtime:_ ~prompt:_ ~report_tool_schema:_ () ->
      Ok (None, ""))
    (fun () ->
      let result =
        AR.review ~evaluator_runtime:"test-empty-evaluator" req
      in
      Alcotest.(check string)
        "gate" "evaluator_empty" (AR.gate_to_string result.AR.gate);
      match result.AR.verdict with
      | AR.Approve ->
        Alcotest.fail
          "expected reject with excuse advisory safety net, got approve"
      | AR.Reject reason ->
        Alcotest.(check bool)
          "mentions safety net"
          true
          (contains_substring (String.lowercase_ascii reason) "safety net"))

let test_review_approves_empty_by_liveness () =
  with_reviewer
    (fun ?sw:_ ~evaluator_runtime:_ ~prompt:_ ~report_tool_schema:_ () ->
      Ok (None, ""))
    (fun () ->
      let result =
        AR.review ~evaluator_runtime:"test-empty-evaluator" (make_request ())
      in
      Alcotest.(check string)
        "gate" "evaluator_empty" (AR.gate_to_string result.AR.gate);
      Alcotest.(check (option string))
        "fallback reason"
        (Some "empty review output")
        result.AR.fallback_reason;
      match result.AR.verdict with
      | AR.Approve -> ()
      | AR.Reject _ ->
        Alcotest.fail
          "empty evaluator output without advisory should approve by liveness (#10474)")

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
            "empty output with excuse advisory rejects (safety net)"
            `Quick
            test_empty_review_rejects_with_excuse_advisory;
          Alcotest.test_case
            "empty evaluator output approves by liveness"
            `Quick
            test_review_approves_empty_by_liveness;
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
    ]
