open Alcotest

module KAR = Masc.Keeper_agent_run
module KTN = Keeper_tool_name
module KTP = Masc.Keeper_tool_progress

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

let tool_call_detail ?(outcome = "ok") tool_name : KAR.tool_call_detail =
  { tool_name
  ; provider = "test"
  ; outcome
  ; typed_outcome = None
  ; latency_ms = 1.0
  ; task_id = None
  ; route_evidence = None
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
            "contract progress filters no-progress tool results"
            `Quick
            test_contract_progress_filters_no_progress_tool_results
        ; test_case
            "material progress does not special-case worktree reuse text"
            `Quick
            test_material_progress_does_not_special_case_worktree_reuse_text
        ] )
    ]
;;
