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

let review () =
  AR.review
    ~evaluator_runtime:"task-reviewer"
    ~question:(AR.Completion { completion_contract = None; required_evidence = [] })
    ~lookup:AR.No_lookup_surface
    ~base_path:(Filename.get_temp_dir_name ())
    request

let test_explicit_base_path_reaches_reviewer () =
  let expected =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-review-base-%d" (Unix.getpid ()))
  in
  let received = ref None in
  with_reviewer
    (fun ~base_path ?sw:_ ~evaluator_runtime:_ ~prompt:_ ~report_tool_schema:_ ~lookup:_ ~on_tool_result:_ ~on_runtime_attempt_error:_ () ->
       received := Some base_path;
       Ok None)
    (fun () ->
       ignore
         (AR.review ~evaluator_runtime:"task-reviewer"
            ~question:(AR.Completion { completion_contract = None; required_evidence = [] })
            ~lookup:AR.No_lookup_surface ~base_path:expected request);
       match !received with
       | Some actual ->
         Alcotest.(check string) "review uses the caller BasePath" expected actual
       | None -> Alcotest.fail "reviewer callback was not called")
;;

let configure_prompt_registry () =
  Prompt_registry.set_markdown_dir
    (Filename.concat (Masc_test_deps.find_project_root ()) "config/prompts")
;;

let test_structured_tool_is_the_only_semantic_verdict () =
  with_reviewer
    (fun ~base_path:_ ?sw:_ ~evaluator_runtime:_ ~prompt:_ ~report_tool_schema:_ ~lookup:_ ~on_tool_result:_ ~on_runtime_attempt_error:_ () ->
       Ok (Some (AR.Approve "")))
    (fun () ->
       let result = review () in
       Alcotest.(check string)
         "gate"
         "structured_tool"
         (AR.gate_to_string result.gate);
       match result.verdict with
       | Some (AR.Approve _) -> ()
       | Some (AR.Reject reason) -> Alcotest.failf "unexpected reject: %s" reason
       | None -> Alcotest.fail "structured verdict was lost")
;;

let test_response_text_is_never_parsed_as_verdict () =
  with_reviewer
    (fun ~base_path:_ ?sw:_ ~evaluator_runtime:_ ~prompt:_ ~report_tool_schema:_ ~lookup:_ ~on_tool_result:_ ~on_runtime_attempt_error:_ () ->
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
    (fun ~base_path:_ ?sw:_ ~evaluator_runtime:_ ~prompt:_ ~report_tool_schema:_ ~lookup:_ ~on_tool_result:_ ~on_runtime_attempt_error:_ () ->
       Error (Agent_core.Error.Internal "review transport unavailable"))
    (fun () ->
       let result = review () in
       Alcotest.(check string)
         "gate"
         "evaluator_unavailable"
         (AR.gate_to_string result.gate);
       Alcotest.(check bool) "no fabricated reject" true (Option.is_none result.verdict))
;;

(* The retry policy this exists for: a review whose single seed message
   already exceeds the target's whole budget cannot be fixed by trying again
   with the same request, so [Agent_core.Error.is_retryable] already reports
   [false] for it (it is an [Agent (HookExecutionFailed _)]). [review] must
   carry that through as [evaluator_error_retryable = Some false] rather than default to the
   always-retry [true] every other gate uses. *)
let test_structural_budget_failure_is_not_retryable () =
  with_reviewer
    (fun ~base_path:_ ?sw:_ ~evaluator_runtime:_ ~prompt:_ ~report_tool_schema:_ ~lookup:_ ~on_tool_result:_ ~on_runtime_attempt_error:_ () ->
       Error
         (Agent_core.Error.Agent
            (Agent_core.Error.HookExecutionFailed
               { hook_name = "model_input_projection"
               ; stage = "turn:parse"
               ; tool_name = None
               ; tool_use_id = None
               ; detail =
                   "newest conversation atom does not fit the model input budget: \
                    available_bytes=233931 newest_atom_bytes=294670"
               })))
    (fun () ->
       let result = review () in
       Alcotest.(check string)
         "gate"
         "evaluator_unavailable"
         (AR.gate_to_string result.gate);
       Alcotest.(check (option bool))
         "classified non-retryable"
         (Some false)
         result.evaluator_error_retryable)
;;

(* Contrast case: a rate limit is exactly the kind of failure retrying is
   supposed to absorb ([Agent_core.Error.is_retryable] reports [true] for
   [Api (RateLimited _)]), so the always-retry default must survive here. *)
let test_rate_limit_failure_stays_retryable () =
  with_reviewer
    (fun ~base_path:_ ?sw:_ ~evaluator_runtime:_ ~prompt:_ ~report_tool_schema:_ ~lookup:_ ~on_tool_result:_ ~on_runtime_attempt_error:_ () ->
       Error
         (Agent_core.Error.Api
            (Agent_core.Error.Retry.RateLimited
               { retry_after = None; message = "rate limited" })))
    (fun () ->
       let result = review () in
       Alcotest.(check string)
         "gate"
         "evaluator_unavailable"
         (AR.gate_to_string result.gate);
       Alcotest.(check (option bool))
         "classified retryable"
         (Some true)
         result.evaluator_error_retryable)
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
       | Ok (AR.Approve _) -> Alcotest.fail "malformed REJECT became APPROVE"
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
  | Ok (AR.Approve _) -> Alcotest.fail "REJECT became APPROVE"
  | Error detail -> Alcotest.fail detail
;;

(* An approval keeps the reviewer's stated reason too. The parser used to read
   [reason] and hand back a nullary [Approve], so what the reviewer said it
   checked never left this function. An omitted reason stays empty: only REJECT
   is refused without one, and failing an approval for a missing sentence would
   be a new gate. *)
let test_approve_reason_is_preserved () =
  (match
     AR.parse_review_verdict_from_json
       (`Assoc
           [ "verdict", `String "APPROVE"
           ; "reason", `String "ran the suite in the sandbox: 9355/9355"
           ])
   with
   | Ok (AR.Approve reason) ->
     Alcotest.(check string)
       "approval reason is not rewritten"
       "ran the suite in the sandbox: 9355/9355"
       reason
   | Ok (AR.Reject _) -> Alcotest.fail "APPROVE became REJECT"
   | Error detail -> Alcotest.fail detail);
  match AR.parse_review_verdict_from_json (`Assoc [ "verdict", `String "APPROVE" ]) with
  | Ok (AR.Approve reason) ->
    Alcotest.(check string) "a silent approval stays silent" "" reason
  | Ok (AR.Reject _) -> Alcotest.fail "APPROVE became REJECT"
  | Error detail -> Alcotest.fail detail
;;

let test_evidence_text_is_not_classified_before_llm_review () =
  Alcotest.(check (list string))
    "only blank values are removed"
    [ "n/a"; "tbd" ]
    (Masc.Task.Completion_review.non_empty_trimmed_strings
       [ " tbd "; ""; " n/a "; "   " ])
;;

(* RFC prompts-and-tool-definitions-outside-ocaml §2.2: the schema handed to
   the reviewer is read from [config/tools/report_review_verdict.toml], whose
   verdict enum is a literal. The variant owns the vocabulary; this mirror
   (the [test_agent_card_action_mirror] idiom) catches drift between the
   literal and [valid_verdict_strings]. *)
let test_verdict_enum_mirrors_valid_verdict_strings () =
  let received = ref None in
  with_reviewer
    (fun ~base_path:_
      ?sw:_
      ~evaluator_runtime:_
      ~prompt:_
      ~report_tool_schema
      ~lookup:_
      ~on_tool_result:_
      ~on_runtime_attempt_error:_
      () ->
       received := Some report_tool_schema;
       Ok None)
    (fun () ->
       ignore (review ());
       match !received with
       | None -> Alcotest.fail "reviewer callback was not called"
       | Some schema ->
         Alcotest.(check string) "tool name" "report_review_verdict" schema.name;
         let verdict_property =
           match schema.input_schema with
           | `Assoc fields ->
             (match List.assoc_opt "properties" fields with
              | Some (`Assoc properties) ->
                (match List.assoc_opt "verdict" properties with
                 | Some verdict -> verdict
                 | None -> Alcotest.fail "properties.verdict missing")
              | _ -> Alcotest.fail "input_schema.properties missing")
           | _ -> Alcotest.fail "input_schema is not an object"
         in
         (match verdict_property with
          | `Assoc fields ->
            (match List.assoc_opt "enum" fields with
             | Some (`List items) ->
               let enum_strings =
                 List.filter_map
                   (function
                     | `String s -> Some s
                     | _ -> None)
                   items
               in
               Alcotest.(check (list string))
                 "verdict enum mirrors valid_verdict_strings"
                 AR.valid_verdict_strings
                 enum_strings
             | _ -> Alcotest.fail "properties.verdict.enum missing")
          | _ -> Alcotest.fail "properties.verdict is not an object"))
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
            "explicit BasePath reaches reviewer"
            `Quick
            test_explicit_base_path_reaches_reviewer
        ; Alcotest.test_case
            "response text ignored"
            `Quick
            test_response_text_is_never_parsed_as_verdict
        ; Alcotest.test_case
            "provider failure unavailable"
            `Quick
            test_evaluator_failure_is_unavailable_not_reject
        ; Alcotest.test_case
            "structural budget failure is not retryable"
            `Quick
            test_structural_budget_failure_is_not_retryable
        ; Alcotest.test_case
            "rate limit failure stays retryable"
            `Quick
            test_rate_limit_failure_stays_retryable
        ; Alcotest.test_case
            "reject without reason is malformed"
            `Quick
            test_reject_without_reason_is_malformed
        ; Alcotest.test_case
            "reject reason is preserved"
            `Quick
            test_reject_reason_is_preserved
        ; Alcotest.test_case
            "approve reason is preserved"
            `Quick
            test_approve_reason_is_preserved
        ; Alcotest.test_case
            "evidence meaning stays with reviewer"
            `Quick
            test_evidence_text_is_not_classified_before_llm_review
        ; Alcotest.test_case
            "verdict enum mirrors valid_verdict_strings"
            `Quick
            test_verdict_enum_mirrors_valid_verdict_strings
        ] )
    ]
