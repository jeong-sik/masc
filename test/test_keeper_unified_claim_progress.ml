open Alcotest

module KAR = Masc_mcp.Keeper_agent_run
module KCC = Masc_mcp.Keeper_contract_classifier
module KTD = Masc_mcp.Keeper_tool_disclosure

let unclaimed_task_context =
  KCC.make_actionable_signal_context
    ~tool_gate_required:false
    ~actionable_signal:KCC.Has_unclaimed_tasks
;;

let no_actionable_context =
  KCC.make_actionable_signal_context
    ~tool_gate_required:false
    ~actionable_signal:KCC.No_actionable_signal
;;

let contains_substring haystack needle =
  let hay_len = String.length haystack in
  let needle_len = String.length needle in
  let rec loop i =
    if i + needle_len > hay_len
    then false
    else if String.sub haystack i needle_len = needle
    then true
    else loop (i + 1)
  in
  needle_len = 0 || loop 0
;;

let test_claim_tool_classification_covers_masc_claim_task () =
  check
    bool
    "keeper claim is claim tool"
    true
    (KTD.is_claim_tool_name "keeper_task_claim");
  check
    bool
    "masc claim next is claim tool"
    true
    (KTD.is_claim_tool_name "masc_claim_next");
  check
    bool
    "masc claim task is claim tool"
    true
    (KTD.is_claim_tool_name "masc_claim_task");
  check
    bool
    "task creation is not claim tool"
    false
    (KTD.is_claim_tool_name "keeper_task_create");
  check
    bool
    "task list is not claim tool"
    false
    (KTD.is_claim_tool_name "keeper_tasks_list")
;;

let test_claim_contract_result_counts_initial_claim_as_execution () =
  let result ?(had_owned_active_task_at_turn_start = false) ?(required = []) tools =
    KAR.tool_contract_result_for_observed_tools
      ~required_tool_names:required
      ~missing_visible_required:[]
      ~had_owned_active_task_at_turn_start
      ~actual_keeper_tool_names:tools
    |> Masc_mcp.Keeper_execution_receipt.tool_contract_result_to_string
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
  check
    string
    "claim does not satisfy unrelated explicit required tool"
    "missing_required_tool_use"
    (result ~required:[ "keeper_task_done" ] [ "keeper_task_claim" ])
;;

let tool_call_detail ?(outcome = "ok") tool_name : KAR.tool_call_detail =
  { tool_name
  ; provider = "test"
  ; outcome
  ; latency_ms = 1.0
  ; task_id = None
  ; route_evidence = None
  }
;;

let test_contract_progress_filters_no_progress_tool_results () =
  let allowed_tool_names = [ "masc_worktree_create"; "keeper_bash" ] in
  let no_progress_only =
    [ tool_call_detail ~outcome:"ok_no_progress" "masc_worktree_create" ]
  in
  check
    (list string)
    "already-existing worktree is not contract progress"
    []
    (KAR.For_testing.progress_keeper_tool_names_for_contract
       ~allowed_tool_names
       ~actual_keeper_tool_names:[ "masc_worktree_create" ]
       ~tool_calls:no_progress_only);
  check
    (list string)
    "already-existing worktree remains visible as no-progress success"
    [ "masc_worktree_create" ]
    (KAR.For_testing.no_progress_success_tool_names_for_contract
       ~allowed_tool_names
       ~tool_calls:no_progress_only);
  check
    (list string)
    "follow-up shell keeps the turn as progress"
    [ "keeper_bash" ]
    (KAR.For_testing.progress_keeper_tool_names_for_contract
       ~allowed_tool_names
       ~actual_keeper_tool_names:[ "masc_worktree_create"; "keeper_bash" ]
       ~tool_calls:
         [ tool_call_detail ~outcome:"ok_no_progress" "masc_worktree_create"
         ; tool_call_detail "keeper_bash"
         ])
;;

let test_actionable_tool_contract_allows_execution_tools () =
  check
    (option string)
    "execution tool satisfies actionable signal"
    None
    (KTD.actionable_tool_contract_violation_reason
       ~claim_context_allowed:true
       ~actionable_signal_context:unclaimed_task_context
       ~tool_names:[ "keeper_bash"; "masc_status" ]);
  check
    (option string)
    "board coordination can satisfy non-owned board signal"
    None
    (KTD.actionable_tool_contract_violation_reason
       ~claim_context_allowed:true
       ~actionable_signal_context:unclaimed_task_context
       ~tool_names:[ "keeper_board_comment" ]);
  (match
     KTD.actionable_tool_contract_violation_reason
       ~claim_context_allowed:false
       ~actionable_signal_context:unclaimed_task_context
       ~tool_names:[ "keeper_board_post"; "keeper_tasks_list" ]
   with
   | Some reason ->
     check
       bool
       "owned task board-only turn requires execution progress"
       true
       (contains_substring reason "without execution progress")
   | None -> fail "expected owned task board-only turn to violate contract");
  check
    (option string)
    "worktree creation satisfies owned task progress"
    None
    (KTD.actionable_tool_contract_violation_reason
       ~claim_context_allowed:false
       ~actionable_signal_context:unclaimed_task_context
       ~tool_names:[ "masc_worktree_create" ]);
  check
    (option string)
    "PR creation satisfies owned task progress"
    None
    (KTD.actionable_tool_contract_violation_reason
       ~claim_context_allowed:false
       ~actionable_signal_context:unclaimed_task_context
       ~tool_names:[ "keeper_pr_create" ]);
  check
    (option string)
    "non-actionable no-op remains allowed"
    None
    (KTD.actionable_tool_contract_violation_reason
       ~claim_context_allowed:true
       ~actionable_signal_context:no_actionable_context
       ~tool_names:[])
;;

let test_discovered_work_classifier_ignores_passive_inspection_tools () =
  let obs =
    { KCC.unclaimed_task_count = 0
    ; board_activity_count = 0
    ; has_discovered_work_section = true
    }
  in
  check
    bool
    "fs read alone cannot make discovered work actionable"
    false
    (KCC.requires_tool_support_for_allowed_tools
       ~allowed_tool_names:[ "keeper_fs_read" ]
       obs);
  check
    bool
    "git status/diff/log surface alone cannot make discovered work actionable"
    false
    (KCC.requires_tool_support_for_allowed_tools
       ~allowed_tool_names:[ "masc_code_git"; "keeper_fs_read" ]
       obs);
  check
    bool
    "draft PR tool makes discovered work actionable"
    true
    (KCC.requires_tool_support_for_allowed_tools
       ~allowed_tool_names:[ "keeper_pr_create" ]
       obs);
  check
    bool
    "execution shell makes discovered work actionable"
    true
    (KCC.requires_tool_support_for_allowed_tools ~allowed_tool_names:[ "keeper_bash" ] obs)
;;

let test_stay_silent_requires_typed_no_work_proof_on_actionable_signal () =
  check
    bool
    "stay_silent satisfies required contract"
    true
    (KTD.tool_name_can_satisfy_required_contract "keeper_stay_silent");
  check
    bool
    "completion tool set includes stay_silent"
    true
    (KTD.is_completion_tool_name "keeper_stay_silent");
  (match
     KTD.actionable_tool_contract_violation_reason
       ~claim_context_allowed:true
       ~actionable_signal_context:unclaimed_task_context
       ~tool_names:[ "keeper_stay_silent"; "keeper_tasks_list" ]
   with
   | Some reason ->
     check
       bool
       "reason mentions typed no-work proof"
       true
       (contains_substring reason "typed no-work proof")
   | None -> fail "expected stay_silent actionable violation");
  check
    (option string)
    "execution plus stay_silent remains accepted"
    None
    (KTD.actionable_tool_contract_violation_reason
       ~claim_context_allowed:true
       ~actionable_signal_context:unclaimed_task_context
       ~tool_names:[ "keeper_board_comment"; "keeper_stay_silent" ]);
  check
    (option string)
    "owned-task progress plus stay_silent remains accepted"
    None
    (KTD.actionable_tool_contract_violation_reason
       ~claim_context_allowed:false
       ~actionable_signal_context:unclaimed_task_context
       ~tool_names:[ "keeper_bash"; "keeper_stay_silent" ]);
  check
    (option string)
    "non-actionable stay_silent remains allowed"
    None
    (KTD.actionable_tool_contract_violation_reason
       ~claim_context_allowed:true
       ~actionable_signal_context:no_actionable_context
       ~tool_names:[ "keeper_stay_silent" ]);
  check
    bool
    "passive-only still violates"
    true
    (Option.is_some
       (KTD.actionable_tool_contract_violation_reason
          ~claim_context_allowed:true
          ~actionable_signal_context:unclaimed_task_context
          ~tool_names:[ "keeper_tasks_list"; "masc_status" ]))
;;

let () =
  run
    "keeper_unified_claim_progress"
    [ ( "claim_progress"
      , [ test_case
            "claim tool classification covers masc claim task"
            `Quick
            test_claim_tool_classification_covers_masc_claim_task
        ; test_case
            "initial claim counts as contract progress"
            `Quick
            test_claim_contract_result_counts_initial_claim_as_execution
        ; test_case
            "contract progress filters no-progress tool results"
            `Quick
            test_contract_progress_filters_no_progress_tool_results
        ; test_case
            "actionable signal allows execution tools"
            `Quick
            test_actionable_tool_contract_allows_execution_tools
        ; test_case
            "discovered work ignores passive inspection tools"
            `Quick
            test_discovered_work_classifier_ignores_passive_inspection_tools
        ; test_case
            "stay_silent needs typed no-work proof on actionable signal"
            `Quick
            test_stay_silent_requires_typed_no_work_proof_on_actionable_signal
        ] )
    ]
;;
