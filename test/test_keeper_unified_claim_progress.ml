open Alcotest

module KAR = Masc.Keeper_agent_run
module KTP = Masc.Keeper_tool_progress

let test_claim_tool_classification_covers_supported_claim_tools () =
  check
    bool
    "keeper claim is claim tool"
    true
    (KTP.is_claim_tool_name "keeper_task_claim");
  check
    bool
    "masc claim next is claim tool"
    true
    (KTP.is_claim_tool_name "masc_claim_next");
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

let test_claim_contract_result_counts_initial_claim_as_execution () =
  let result ?(had_owned_active_task_at_turn_start = false) tools =
    KAR.tool_contract_result_for_observed_tools
      ~had_owned_active_task_at_turn_start
      ~actual_keeper_tool_names:tools
    |> Masc.Keeper_execution_receipt.tool_contract_result_to_string
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
  let allowed_tool_names = [ "keeper_task_claim"; "tool_execute" ] in
  let no_progress_only =
    [ tool_call_detail ~outcome:"ok_no_progress" "keeper_task_claim" ]
  in
  check
    (list string)
    "claim-only result is not contract progress"
    []
    (KAR.For_testing.progress_keeper_tool_names_for_contract
       ~allowed_tool_names
       ~actual_keeper_tool_names:[ "keeper_task_claim" ]
       ~tool_calls:no_progress_only);
  check
    (list string)
    "claim remains visible as no-progress success"
    [ "keeper_task_claim" ]
    (KAR.For_testing.no_progress_success_tool_names_for_contract
       ~allowed_tool_names
       ~tool_calls:no_progress_only);
  check
    (list string)
    "follow-up shell keeps the turn as progress"
    [ "tool_execute" ]
    (KAR.For_testing.progress_keeper_tool_names_for_contract
       ~allowed_tool_names
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
            "claim tool classification covers supported claim tools"
            `Quick
            test_claim_tool_classification_covers_supported_claim_tools
        ; test_case
            "initial claim counts as contract progress"
            `Quick
            test_claim_contract_result_counts_initial_claim_as_execution
        ; test_case
            "contract progress filters no-progress tool results"
            `Quick
            test_contract_progress_filters_no_progress_tool_results
        ] )
    ]
;;
