module AR = Masc.Task.Anti_rationalization

let request : AR.review_request =
  { agent_name = "test-keeper"
  ; task_title = "finish concrete task"
  ; task_description = "Implement and verify a concrete task."
  ; completion_notes = "Implemented the change and ran the focused test."
  ; task_id = "test-task"
  ; evidence_refs = []
  }
;;

let with_reviewer reviewer f =
  let saved = Atomic.get AR.run_llm_reviewer_fn in
  Fun.protect
    ~finally:(fun () -> Atomic.set AR.run_llm_reviewer_fn saved)
    (fun () ->
       Atomic.set AR.run_llm_reviewer_fn reviewer;
       f ())
;;

let review () = AR.review ~evaluator_runtime:"task-reviewer" request

let configure_prompt_registry () =
  Prompt_registry.set_markdown_dir
    (Filename.concat (Masc_test_deps.find_project_root ()) "config/prompts")
;;

let test_structured_tool_is_the_only_semantic_verdict () =
  with_reviewer
    (fun ?sw:_ ~evaluator_runtime:_ ~prompt:_ ~report_tool_schema:_ () ->
       Ok (Some AR.Approve))
    (fun () ->
       let result = review () in
       Alcotest.(check string)
         "gate"
         "structured_tool"
         (AR.gate_to_string result.gate);
       match result.verdict with
       | Some AR.Approve -> ()
       | Some (AR.Reject reason) -> Alcotest.failf "unexpected reject: %s" reason
       | None -> Alcotest.fail "structured verdict was lost")
;;

let test_response_text_is_never_parsed_as_verdict () =
  with_reviewer
    (fun ?sw:_ ~evaluator_runtime:_ ~prompt:_ ~report_tool_schema:_ () ->
       Ok None)
    (fun () ->
       let result = review () in
       Alcotest.(check string)
         "gate"
         "invalid_verdict"
         (AR.gate_to_string result.gate);
       Alcotest.(check bool) "no semantic verdict" true (Option.is_none result.verdict))
;;

let test_evaluator_failure_is_unavailable_not_reject () =
  with_reviewer
    (fun ?sw:_ ~evaluator_runtime:_ ~prompt:_ ~report_tool_schema:_ () ->
       Error (Agent_sdk.Error.Internal "review transport unavailable"))
    (fun () ->
       let result = review () in
       Alcotest.(check string)
         "gate"
         "evaluator_unavailable"
         (AR.gate_to_string result.gate);
       Alcotest.(check bool) "no fabricated reject" true (Option.is_none result.verdict))
;;

let test_reject_without_reason_is_malformed () =
  let malformed =
    [ `Assoc [ "verdict", `String "REJECT" ]
    ; `Assoc [ "verdict", `String "REJECT"; "reason", `String "   " ]
    ; `Assoc [ "verdict", `String "REJECT"; "reason", `Null ]
    ]
  in
  List.iter
    (fun args ->
       match AR.parse_review_verdict_from_json args with
       | Error _ -> ()
       | Ok AR.Approve -> Alcotest.fail "malformed REJECT became APPROVE"
       | Ok (AR.Reject reason) ->
         Alcotest.failf "malformed REJECT fabricated a reason: %s" reason)
    malformed
;;

let test_reject_reason_is_preserved () =
  match
    AR.parse_review_verdict_from_json
      (`Assoc
          [ "verdict", `String "REJECT"
          ; "reason", `String " evidence is incomplete "
          ])
  with
  | Ok (AR.Reject reason) ->
    Alcotest.(check string) "rejection reason is not rewritten" " evidence is incomplete " reason
  | Ok AR.Approve -> Alcotest.fail "REJECT became APPROVE"
  | Error detail -> Alcotest.fail detail
;;

let test_evidence_text_is_not_classified_before_llm_review () =
  Alcotest.(check (list string))
    "only blank values are removed"
    [ "n/a"; "tbd" ]
    (Masc.Task.Completion_review.non_empty_trimmed_strings
       [ " tbd "; ""; " n/a "; "   " ])
;;

let () =
  configure_prompt_registry ();
  Alcotest.run
    "anti_rationalization_structured_only"
    [ ( "review boundary"
      , [ Alcotest.test_case
            "structured tool verdict"
            `Quick
            test_structured_tool_is_the_only_semantic_verdict
        ; Alcotest.test_case
            "response text ignored"
            `Quick
            test_response_text_is_never_parsed_as_verdict
        ; Alcotest.test_case
            "provider failure unavailable"
            `Quick
            test_evaluator_failure_is_unavailable_not_reject
        ; Alcotest.test_case
            "reject without reason is malformed"
            `Quick
            test_reject_without_reason_is_malformed
        ; Alcotest.test_case
            "reject reason is preserved"
            `Quick
            test_reject_reason_is_preserved
        ; Alcotest.test_case
            "evidence meaning stays with reviewer"
            `Quick
            test_evidence_text_is_not_classified_before_llm_review
        ] )
    ]
