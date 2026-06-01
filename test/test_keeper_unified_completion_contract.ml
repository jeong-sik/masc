open Alcotest

module KCC = Masc_mcp.Keeper_contract_classifier
module KTC = Masc_mcp.Keeper_tool_completion_contract
module KTO = Masc_mcp.Keeper_tool_observation
module KTP = Masc_mcp.Keeper_tool_progress

let unclaimed_task_context =
  KCC.make_actionable_signal_context
    ~tool_gate_required:false
    ~actionable_signal:KCC.Has_unclaimed_tasks
;;

let board_activity_context =
  KCC.make_actionable_signal_context
    ~tool_gate_required:false
    ~actionable_signal:KCC.Has_board_activity
;;

let tool_gate_context =
  KCC.make_actionable_signal_context
    ~tool_gate_required:true
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

let test_validate_completion_contract_allows_text_without_tools () =
  match
    KTC.validate_completion_contract ~contract:KTC.Allow_text_or_tool ~tool_names:[] ()
  with
  | Ok () -> ()
  | Error e -> fail ("unexpected error: " ^ e)
;;

let test_validate_completion_contract_requires_tool_use () =
  match
    KTC.validate_completion_contract ~contract:KTC.Require_tool_use ~tool_names:[] ()
  with
  | Ok () -> fail "expected tool contract failure"
  | Error e ->
    check
      bool
      "error mentions required tool contract"
      true
      (contains_substring e "required tool contract")
;;

let test_validate_completion_contract_accepts_stay_silent () =
  match
    KTC.validate_completion_contract
      ~contract:KTC.Require_tool_use
      ~tool_names:[ "keeper_stay_silent" ]
      ()
  with
  | Ok () -> ()
  | Error e -> fail ("unexpected error: " ^ e)
;;

let test_unexpected_tool_names_accepts_keeper_surface () =
  check
    (list string)
    "no unexpected tools"
    []
    (KTO.unexpected_tool_names
       ~allowed_tool_names:[ "keeper_task_claim"; "keeper_board_comment"; "extend_turns" ]
       ~tool_names:[ "keeper_task_claim"; "extend_turns" ])
;;

let test_unexpected_tool_names_reports_foreign_surface () =
  check
    (list string)
    "foreign tools flagged"
    [ "Skill"; "Execute"; "Agent" ]
    (KTO.unexpected_tool_names
       ~allowed_tool_names:[ "keeper_task_claim"; "keeper_board_comment"; "extend_turns" ]
       ~tool_names:[ "keeper_task_claim"; "Skill"; "Execute"; "Skill"; "Agent" ])
;;

let test_completion_contract_of_tool_choice_allows_auto () =
  check
    bool
    "auto allows text"
    true
    (match KTC.completion_contract_of_tool_choice None with
     | KTC.Allow_text_or_tool -> true
     | KTC.Require_tool_use -> false);
  check
    bool
    "none allows text"
    true
    (match KTC.completion_contract_of_tool_choice (Some Agent_sdk.Types.None_) with
     | KTC.Allow_text_or_tool -> true
     | KTC.Require_tool_use -> false)
;;

let test_completion_contract_of_tool_choice_requires_any () =
  check
    bool
    "any requires tool use"
    true
    (match KTC.completion_contract_of_tool_choice (Some Agent_sdk.Types.Any) with
     | KTC.Require_tool_use -> true
     | KTC.Allow_text_or_tool -> false)
;;

let test_run_completion_contract_latches_required_tool_use () =
  check
    bool
    "required tool use stays latched across run"
    true
    (match
       KTC.run_completion_contract
         ~turn_contract:KTC.Allow_text_or_tool
         ~required_tool_use_seen:true
     with
     | KTC.Require_tool_use -> true
     | KTC.Allow_text_or_tool -> false);
  check
    bool
    "optional stays optional when no required turn seen"
    true
    (match
       KTC.run_completion_contract
         ~turn_contract:KTC.Allow_text_or_tool
         ~required_tool_use_seen:false
     with
     | KTC.Allow_text_or_tool -> true
     | KTC.Require_tool_use -> false)
;;

let test_validate_completion_contract_presence_requires_keeper_surface_tool () =
  (match
     KTC.validate_completion_contract_presence
       ~contract:KTC.Require_tool_use
       ~tool_present:true
   with
   | Ok () -> ()
   | Error e -> fail ("unexpected error: " ^ e));
  match
    KTC.validate_completion_contract_presence
      ~contract:KTC.Require_tool_use
      ~tool_present:false
  with
  | Ok () -> fail "expected keeper-surface contract failure"
  | Error e ->
    check
      bool
      "error mentions keeper-surface tools"
      true
      (contains_substring e "keeper-surface tools")
;;

let test_actionable_tool_contract_flags_no_tools () =
  check
    (option string)
    "no tools no longer violates actionable signal"
    None
    (KTP.actionable_tool_contract_violation_reason
       ~claim_context_allowed:true
       ~actionable_signal_context:unclaimed_task_context
       ~tool_names:[])
;;

let test_actionable_tool_contract_preserves_turn_gate_context () =
  check
    (option string)
    "turn affordance gate no longer emits violation"
    None
    (KTP.actionable_tool_contract_violation_reason
       ~claim_context_allowed:true
       ~actionable_signal_context:tool_gate_context
       ~tool_names:[])
;;

let test_actionable_tool_contract_flags_passive_only_tools () =
  check
    (option string)
    "passive-only tools no longer violate actionable signal"
    None
    (KTP.actionable_tool_contract_violation_reason
       ~claim_context_allowed:true
       ~actionable_signal_context:board_activity_context
       ~tool_names:[ "keeper_board_get"; "masc_status" ])
;;

let test_actionable_tool_contract_rejects_claim_context_when_already_claimed () =
  check
    (option string)
    "claim context no longer violates after ownership"
    None
    (KTP.actionable_tool_contract_violation_reason
       ~claim_context_allowed:false
       ~actionable_signal_context:unclaimed_task_context
       ~tool_names:[ "keeper_task_claim" ]);
  check
    (option string)
    "claim context remains allowed before ownership"
    None
    (KTP.actionable_tool_contract_violation_reason
       ~claim_context_allowed:true
       ~actionable_signal_context:unclaimed_task_context
       ~tool_names:[ "keeper_task_claim" ])
;;

let test_actionable_tool_contract_rejects_stay_silent_when_already_claimed () =
  let check_no_violation label tool_names =
    check
      (option string)
      (label ^ " no longer violates owned task")
      None
      (KTP.actionable_tool_contract_violation_reason
         ~claim_context_allowed:false
         ~actionable_signal_context:unclaimed_task_context
         ~tool_names)
  in
  check_no_violation "stay_silent alone" [ "keeper_stay_silent" ];
  check_no_violation
    "stay_silent plus passive"
    [ "keeper_stay_silent"; "keeper_tasks_list"; "masc_status" ];
  check_no_violation "claim plus passive" [ "keeper_task_claim"; "keeper_tasks_list" ];
  check
    (option string)
    "task completion still satisfies owned task"
    None
    (KTP.actionable_tool_contract_violation_reason
       ~claim_context_allowed:false
       ~actionable_signal_context:unclaimed_task_context
       ~tool_names:[ "keeper_task_done" ])
;;

let () =
  run
    "keeper_unified_completion_contract"
    [ ( "completion_contract"
      , [ test_case
            "completion contract allows text without tools"
            `Quick
            test_validate_completion_contract_allows_text_without_tools
        ; test_case
            "completion contract requires tool use"
            `Quick
            test_validate_completion_contract_requires_tool_use
        ; test_case
            "completion contract accepts stay silent"
            `Quick
            test_validate_completion_contract_accepts_stay_silent
        ; test_case
            "unexpected tool names accepts keeper surface"
            `Quick
            test_unexpected_tool_names_accepts_keeper_surface
        ; test_case
            "unexpected tool names reports foreign surface"
            `Quick
            test_unexpected_tool_names_reports_foreign_surface
        ; test_case
            "completion contract mapping allows auto"
            `Quick
            test_completion_contract_of_tool_choice_allows_auto
        ; test_case
            "completion contract mapping requires any"
            `Quick
            test_completion_contract_of_tool_choice_requires_any
        ; test_case
            "run completion contract latches required tool use"
            `Quick
            test_run_completion_contract_latches_required_tool_use
        ; test_case
            "completion contract presence requires keeper-surface tool"
            `Quick
            test_validate_completion_contract_presence_requires_keeper_surface_tool
        ; test_case
            "actionable signal allows no tools"
            `Quick
            test_actionable_tool_contract_flags_no_tools
        ; test_case
            "actionable signal preserves turn-gate context"
            `Quick
            test_actionable_tool_contract_preserves_turn_gate_context
        ; test_case
            "actionable signal allows passive-only tools"
            `Quick
            test_actionable_tool_contract_flags_passive_only_tools
        ; test_case
            "actionable signal allows claim context after ownership"
            `Quick
            test_actionable_tool_contract_rejects_claim_context_when_already_claimed
        ; test_case
            "actionable signal allows stay_silent after ownership"
            `Quick
            test_actionable_tool_contract_rejects_stay_silent_when_already_claimed
        ] )
    ]
;;
