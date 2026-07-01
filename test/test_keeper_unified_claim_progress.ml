open Alcotest

module KAR = Masc.Keeper_agent_run
module KTN = Keeper_tool_name
module KTP = Masc.Keeper_tool_progress
module KUS = Masc.Keeper_unified_metrics_support
module Outcome = Keeper_tool_outcome

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

let test_claim_tool_classification_covers_supported_claim_tools () =
  check
    bool
    "keeper claim is claim tool"
    true
    (KTP.is_claim_tool_name "keeper_task_claim");

  check
    bool
    "removed claim task alias is not claim tool"
    false
    (KTP.is_claim_tool_name "masc_claim_task");
  check
    bool
    "task creation is not claim tool"
    false
    (KTP.is_claim_tool_name "keeper_task_create");
  check
    bool
    "task list is not claim tool"
    false
    (KTP.is_claim_tool_name "keeper_tasks_list")
;;

let test_completion_tool_classification_covers_keeper_and_public_projection () =
  check
    bool
    "keeper task done is completion"
    true
    (KTP.is_completion_tool_name "keeper_task_done");
  check
    bool
    "public masc deliver is completion"
    true
    (KTP.is_completion_tool_name "masc_deliver");
  check
    bool
    "task list is not completion"
    false
    (KTP.is_completion_tool_name "keeper_tasks_list")
;;

let test_board_tool_access_uses_keeper_owned_surface_names () =
  check
    bool
    "keeper board wrapper counts as board surface"
    true
    (KTN.is_board_surface_name "keeper_board_post");
  check
    bool
    "legacy public board name counts as board surface"
    true
    (KTN.is_board_surface_name "masc_board_post");
  check
    bool
    "non-board keeper task tool does not count as board surface"
    false
    (KTN.is_board_surface_name "keeper_task_claim")
;;

let test_claim_contract_result_counts_initial_claim_as_execution () =
  let result ?(had_owned_active_task_at_turn_start = false) tools =
    KAR.completion_contract_result_for_progress_evidence
      ~had_owned_active_task_at_turn_start
      ~actual_keeper_tool_names:tools
    |> Masc.Keeper_execution_receipt.completion_contract_result_to_string
  in
  check
    string
    "initial claim is execution progress"
    "satisfied_execution"
    (result [ "keeper_task_claim" ]);
  check
    string
    "initial claim plus passive reads is still progress"
    "satisfied_execution"
    (result [ "keeper_task_claim"; "keeper_tasks_list" ]);
  check
    string
    "claim after already owning task stays diagnostic"
    "claim_only_after_owned_task"
    (result ~had_owned_active_task_at_turn_start:true [ "keeper_task_claim" ]);
  ()
;;

let test_execution_tools_satisfy_contract_progress () =
  let result tools =
    KAR.completion_contract_result_for_progress_evidence
      ~had_owned_active_task_at_turn_start:true
      ~actual_keeper_tool_names:tools
    |> Masc.Keeper_execution_receipt.completion_contract_result_to_string
  in
  check
    string
    "execute tool counts as execution progress"
    "satisfied_execution"
    (result [ "tool_execute" ]);
  check
    string
    "board write counts as execution progress"
    "satisfied_execution"
    (result [ "keeper_board_post" ]);
  check
    string
    "passive status tools remain passive"
    "passive_only"
    (result [ "keeper_tasks_list" ]);
  ()
;;

let test_empty_no_tool_response_violates_contract () =
  let result ~response_text_present =
    KAR.Contract_helpers.observed_completion_contract_status
      ~had_owned_active_task_at_turn_start:false
      ~actual_keeper_tool_names:[]
      ~stop_reason:Runtime_agent.Completed
      ~response_text_present
    |> Masc.Keeper_execution_receipt.completion_contract_result_to_string
  in
  check
    string
    "empty no-tool response is not satisfied completion"
    "violated"
    (result ~response_text_present:false);
  check
    string
    "visible no-tool response remains completion"
    "satisfied_completion"
    (result ~response_text_present:true)
;;

let test_budget_exhausted_tool_only_execution_does_not_satisfy_contract () =
  let result ?(response_text_present = false) tools =
    KAR.Contract_helpers.observed_completion_contract_status
      ~had_owned_active_task_at_turn_start:false
      ~actual_keeper_tool_names:tools
      ~stop_reason:(Runtime_agent.TurnBudgetExhausted { turns_used = 60; limit = 60 })
      ~response_text_present
    |> Masc.Keeper_execution_receipt.completion_contract_result_to_string
  in
  check
    string
    "execution tool with no deliverable reply is not satisfied execution"
    "needs_execution_progress"
    (result [ "tool_execute" ]);
  check
    string
    "raw text is ignored when the stop reason suppresses visible text"
    "needs_execution_progress"
    (result ~response_text_present:true [ "tool_execute" ]);
  check
    string
    "initial claim also cannot satisfy a budget-exhausted empty reply"
    "needs_execution_progress"
    (result [ "keeper_task_claim" ]);
  check
    string
    "explicit completion tool remains completion evidence"
    "satisfied_completion"
    (result [ "keeper_task_done" ]);
  check
    string
    "empty no-tool budget exhaustion remains a violation"
    "violated"
    (result [])
;;

let tool_call_detail ?(outcome = "ok") tool_name : KAR.tool_call_detail =
  { tool_name
  ; provider = "test"
  ; outcome
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

let test_material_progress_does_not_special_case_worktree_reuse_text () =
  check
    bool
    "empty output has no material progress"
    false
    (KTP.tool_result_has_material_progress
       ~tool_name:"tool_execute"
       ~output_text:"");
  check
    bool
    "worktree reuse text is just tool output"
    true
    (KTP.tool_result_has_material_progress
       ~tool_name:"tool_execute"
       ~output_text:
         "Worktree already exists: /tmp/repo/.worktrees/task\n\
          Branch already checked out: feature/task\n")
;;

let test_no_work_outcome_maps_to_empty_queue_sleep () =
  let turn_effect =
    KTP.classify_tool_progress_with_outcome
      "keeper_task_claim"
      (Some (Outcome.No_progress { reason = Outcome.No_work_available }))
  in
  match turn_effect with
  | KTP.Streak_reset_and_empty_queue_sleep { reason = KTP.No_work_to_report } -> ()
  | KTP.Streak_increment -> fail "expected empty queue sleep, got streak increment"
  | KTP.Streak_reset -> fail "expected empty queue sleep, got streak reset"
  | KTP.Streak_reset_and_empty_queue_sleep { reason = KTP.No_eligible_tasks _ } ->
    fail "expected no-work reason"
;;

let () =
  run
    "keeper_unified_claim_progress"
    [ ( "claim_progress"
      , [ test_case
            "claim tool classification covers supported claim tools"
            `Quick
            test_claim_tool_classification_covers_supported_claim_tools
        ; test_case
            "completion classification covers keeper and public projection"
            `Quick
            test_completion_tool_classification_covers_keeper_and_public_projection
        ; test_case
            "board access check uses keeper-owned surface names"
            `Quick
            test_board_tool_access_uses_keeper_owned_surface_names
        ; test_case
            "initial claim counts as contract progress"
            `Quick
            test_claim_contract_result_counts_initial_claim_as_execution
        ; test_case
            "execution tools satisfy contract progress"
            `Quick
            test_execution_tools_satisfy_contract_progress
        ; test_case
            "empty no-tool response violates completion contract"
            `Quick
            test_empty_no_tool_response_violates_contract
        ; test_case
            "budget-exhausted tool-only execution does not satisfy contract"
            `Quick
            test_budget_exhausted_tool_only_execution_does_not_satisfy_contract
        ; test_case
            "contract progress filters no-progress tool results"
            `Quick
            test_contract_progress_filters_no_progress_tool_results
        ; test_case
            "material progress does not special-case worktree reuse text"
            `Quick
            test_material_progress_does_not_special_case_worktree_reuse_text
        ; test_case
            "no-work typed outcome maps to empty queue sleep"
            `Quick
            test_no_work_outcome_maps_to_empty_queue_sleep
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
