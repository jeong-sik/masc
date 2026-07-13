open Alcotest

module KAR = Masc.Keeper_agent_run
module KUS = Masc.Keeper_unified_metrics_support

(* RFC-0232: a budget-exhausted (Continuation_checkpoint) turn substitutes a
   synthetic continuation notice for the reply text. That text is display-only;
   the work preview must gate visible model text on [is_visible_reply] so the
   canned "Continuation checkpoint saved; ..." sentence never surfaces as
   output. These pin the preview precedence. *)
let test_preview_shows_visible_model_text () =
  check string "visible reply -> model text wins" "real answer"
    (KUS.select_proactive_preview ~previous:"old" ~has_text:true
       ~is_visible_reply:true ~has_substantive_tools:false ~tool_names:[]
       ~response_text:"real answer" ~validated_evidence_preview:None)

let test_preview_drops_continuation_notice () =
  (* has_text is true (the synthetic notice is non-empty) but the outcome is
     not a visible reply -> the notice must NOT become the preview. With no
     tools and no evidence, the prior preview is kept. *)
  check string "checkpoint notice does not overwrite preview" "old"
    (KUS.select_proactive_preview ~previous:"old" ~has_text:true
       ~is_visible_reply:false ~has_substantive_tools:false ~tool_names:[]
       ~response_text:"Continuation checkpoint saved; keeper remains scheduled."
       ~validated_evidence_preview:None)

let test_preview_falls_back_to_tools_then_evidence () =
  check string "checkpoint with tools -> tool summary"
    "(tools: keeper_task_claim)"
    (KUS.select_proactive_preview ~previous:"old" ~has_text:true
       ~is_visible_reply:false ~has_substantive_tools:true
       ~tool_names:[ "keeper_task_claim" ]
       ~response_text:"Continuation checkpoint saved; keeper remains scheduled."
       ~validated_evidence_preview:None);
  check string "no text, no tools -> validated evidence" "(validated evidence)"
    (KUS.select_proactive_preview ~previous:"old" ~has_text:false
       ~is_visible_reply:true ~has_substantive_tools:false ~tool_names:[]
       ~response_text:"" ~validated_evidence_preview:(Some "(validated evidence)"))

let test_empty_no_tool_response_is_no_visible_output () =
  let result ~response_text_present =
    KAR.Contract_helpers.observed_completion_evidence
      ~actual_keeper_tool_names:[]
      ~stop_reason:Runtime_agent.Completed
      ~response_text_present
    |> Masc.Keeper_execution_receipt.completion_contract_result_to_string
  in
  check
    string
    "empty no-tool response is observed without visible output"
    "no_visible_output"
    (result ~response_text_present:false);
  check
    string
    "visible no-tool response records response evidence"
    "response_observed"
    (result ~response_text_present:true)
;;

let test_budget_exhaustion_is_contract_neutral () =
  let result ?(response_text_present = false) tools =
    KAR.Contract_helpers.observed_completion_evidence
      ~actual_keeper_tool_names:tools
      ~stop_reason:(Runtime_agent.TurnBudgetExhausted { turns_used = 60; limit = 60 })
      ~response_text_present
    |> Masc.Keeper_execution_receipt.completion_contract_result_to_string
  in
  check
    string
    "tool call does not become a budget-derived failure"
    "unknown"
    (result [ "tool_execute" ]);
  check
    string
    "raw text does not become a budget-derived verdict"
    "unknown"
    (result ~response_text_present:true [ "tool_execute" ]);
  check
    string
    "tool identity does not change budget neutrality"
    "unknown"
    (result [ "keeper_task_claim" ]);
  check
    string
    "completion-like names do not get special treatment"
    "unknown"
    (result [ "keeper_task_done" ]);
  check
    string
    "empty budget exhaustion remains neutral"
    "unknown"
    (result [])
;;

let test_recovery_defer_is_not_a_runtime_failure () =
  let result =
    KAR.Contract_helpers.observed_completion_evidence
      ~actual_keeper_tool_names:[ "tool_execute" ]
      ~stop_reason:
        (Runtime_agent.ToolFailureRecoveryDeferred
           { turns_used = 2
           ; reason = "wait for repository state"
           ; tool_names = [ "Execute" ]
           })
      ~response_text_present:false
    |> Masc.Keeper_execution_receipt.completion_contract_result_to_string
  in
  check
    string
    "typed control checkpoint is completion-contract neutral"
    "unknown"
    result
;;

let tool_call_detail ?(outcome = "ok") tool_name : KAR.tool_call_detail =
  { tool_name
  ; provider = "test"
  ; outcome
  ; execution_outcome = Tool_result.Ok
  ; typed_outcome = None
  ; latency_ms = 1.0
  ; task_id = None
  ; route_evidence = None
  ; input_fingerprint = Some "input"
  ; output_fingerprint = Some "output"
  }
;;

let test_contract_progress_filters_no_progress_tool_results () =
  let no_progress_only =
    [ tool_call_detail ~outcome:"ok_no_progress" "keeper_task_claim" ]
  in
  check
    (list string)
    "claim-only result is not contract progress"
    []
    (KAR.For_testing.progress_keeper_tool_names_for_contract
       ~actual_keeper_tool_names:[ "keeper_task_claim" ]
       ~tool_calls:no_progress_only);
  check
    (list string)
    "follow-up shell keeps the turn as progress"
    [ "tool_execute" ]
    (KAR.For_testing.progress_keeper_tool_names_for_contract
       ~actual_keeper_tool_names:[ "keeper_task_claim"; "tool_execute" ]
       ~tool_calls:
         [ tool_call_detail ~outcome:"ok_no_progress" "keeper_task_claim"
         ; tool_call_detail "tool_execute"
         ])
;;

let () =
  run
    "keeper_unified_claim_progress"
    [ ( "claim_progress"
      , [ test_case
            "empty no-tool response records no visible output"
            `Quick
            test_empty_no_tool_response_is_no_visible_output
        ; test_case
            "budget exhaustion is completion-contract neutral"
            `Quick
            test_budget_exhaustion_is_contract_neutral
        ; test_case
            "recovery defer is completion-contract neutral"
            `Quick
            test_recovery_defer_is_not_a_runtime_failure
        ; test_case
            "contract progress filters no-progress tool results"
            `Quick
            test_contract_progress_filters_no_progress_tool_results
        ] )
    ; ( "preview_precedence"
      , [ test_case
            "visible reply shows model text"
            `Quick
            test_preview_shows_visible_model_text
        ; test_case
            "continuation notice does not overwrite preview"
            `Quick
            test_preview_drops_continuation_notice
        ; test_case
            "falls back to tools then validated evidence"
            `Quick
            test_preview_falls_back_to_tools_then_evidence
        ] )
    ]
;;
