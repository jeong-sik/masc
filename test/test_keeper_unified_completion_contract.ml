open Alcotest

module KCC = Masc_mcp.Keeper_contract_classifier
module KTD = Masc_mcp.Keeper_tool_disclosure

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
    KTD.validate_completion_contract ~contract:KTD.Allow_text_or_tool ~tool_names:[] ()
  with
  | Ok () -> ()
  | Error e -> fail ("unexpected error: " ^ e)
;;

let test_validate_completion_contract_requires_tool_use () =
  match
    KTD.validate_completion_contract ~contract:KTD.Require_tool_use ~tool_names:[] ()
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
    KTD.validate_completion_contract
      ~contract:KTD.Require_tool_use
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
    (KTD.unexpected_tool_names
       ~allowed_tool_names:[ "keeper_task_claim"; "keeper_board_comment"; "extend_turns" ]
       ~tool_names:[ "keeper_task_claim"; "extend_turns" ])
;;

let test_unexpected_tool_names_reports_foreign_surface () =
  check
    (list string)
    "foreign tools flagged"
    [ "Skill"; "Bash"; "Agent" ]
    (KTD.unexpected_tool_names
       ~allowed_tool_names:[ "keeper_task_claim"; "keeper_board_comment"; "extend_turns" ]
       ~tool_names:[ "keeper_task_claim"; "Skill"; "Bash"; "Skill"; "Agent" ])
;;

let test_completion_contract_of_tool_choice_allows_auto () =
  check
    bool
    "auto allows text"
    true
    (match KTD.completion_contract_of_tool_choice None with
     | KTD.Allow_text_or_tool -> true
     | KTD.Require_tool_use -> false);
  check
    bool
    "none allows text"
    true
    (match KTD.completion_contract_of_tool_choice (Some Agent_sdk.Types.None_) with
     | KTD.Allow_text_or_tool -> true
     | KTD.Require_tool_use -> false)
;;

let test_completion_contract_of_tool_choice_requires_any () =
  check
    bool
    "any requires tool use"
    true
    (match KTD.completion_contract_of_tool_choice (Some Agent_sdk.Types.Any) with
     | KTD.Require_tool_use -> true
     | KTD.Allow_text_or_tool -> false)
;;

let test_run_completion_contract_latches_required_tool_use () =
  check
    bool
    "required tool use stays latched across run"
    true
    (match
       KTD.run_completion_contract
         ~turn_contract:KTD.Allow_text_or_tool
         ~required_tool_use_seen:true
     with
     | KTD.Require_tool_use -> true
     | KTD.Allow_text_or_tool -> false);
  check
    bool
    "optional stays optional when no required turn seen"
    true
    (match
       KTD.run_completion_contract
         ~turn_contract:KTD.Allow_text_or_tool
         ~required_tool_use_seen:false
     with
     | KTD.Allow_text_or_tool -> true
     | KTD.Require_tool_use -> false)
;;

let test_validate_completion_contract_presence_requires_keeper_surface_tool () =
  (match
     KTD.validate_completion_contract_presence
       ~contract:KTD.Require_tool_use
       ~tool_present:true
   with
   | Ok () -> ()
   | Error e -> fail ("unexpected error: " ^ e));
  match
    KTD.validate_completion_contract_presence
      ~contract:KTD.Require_tool_use
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
  match
    KTD.actionable_tool_contract_violation_reason
      ~claim_context_allowed:true
      ~actionable_signal_context:unclaimed_task_context
      ~tool_names:[]
  with
  | Some reason ->
    check
      bool
      "reason mentions no keeper tools"
      true
      (contains_substring reason "no keeper tools");
    check
      bool
      "reason preserves signal kind"
      true
      (contains_substring reason "has_unclaimed_tasks")
  | None -> fail "expected actionable no-tool violation"
;;

let test_actionable_tool_contract_preserves_turn_gate_context () =
  match
    KTD.actionable_tool_contract_violation_reason
      ~claim_context_allowed:true
      ~actionable_signal_context:tool_gate_context
      ~tool_names:[]
  with
  | Some reason ->
    check
      bool
      "reason preserves turn affordance gate"
      true
      (contains_substring reason "turn_affordance_requires_tool")
  | None -> fail "expected tool-gate no-tool violation"
;;

let test_actionable_tool_contract_flags_passive_only_tools () =
  match
    KTD.actionable_tool_contract_violation_reason
      ~claim_context_allowed:true
      ~actionable_signal_context:board_activity_context
      ~tool_names:[ "keeper_board_get"; "masc_status" ]
  with
  | Some reason ->
    check
      bool
      "reason mentions passive tools"
      true
      (contains_substring reason "passive status/read tools");
    check
      bool
      "reason preserves board signal kind"
      true
      (contains_substring reason "has_board_activity")
  | None -> fail "expected actionable passive-only violation"
;;

let test_actionable_tool_contract_rejects_claim_context_when_already_claimed () =
  let () =
    match
      KTD.actionable_tool_contract_violation_reason
        ~claim_context_allowed:false
        ~actionable_signal_context:unclaimed_task_context
        ~tool_names:[ "keeper_task_claim" ]
    with
    | Some reason ->
      check
        bool
        "reason mentions execution progress"
        true
        (contains_substring reason "without execution progress")
    | None -> fail "expected actionable claim-context-only violation"
  in
  check
    (option string)
    "claim context is allowed before ownership"
    None
    (KTD.actionable_tool_contract_violation_reason
       ~claim_context_allowed:true
       ~actionable_signal_context:unclaimed_task_context
       ~tool_names:[ "keeper_task_claim" ])
;;

let test_actionable_tool_contract_rejects_stay_silent_when_already_claimed () =
  let check_violation label tool_names =
    match
      KTD.actionable_tool_contract_violation_reason
        ~claim_context_allowed:false
        ~actionable_signal_context:unclaimed_task_context
        ~tool_names
    with
    | Some reason ->
      check
        bool
        (label ^ " mentions owned active task")
        true
        (contains_substring reason "owned active task");
      check
        bool
        (label ^ " mentions execution progress")
        true
        (contains_substring reason "without execution progress")
    | None -> fail (label ^ ": expected owned-task silence violation")
  in
  check_violation "stay_silent alone" [ "keeper_stay_silent" ];
  check_violation
    "stay_silent plus passive"
    [ "keeper_stay_silent"; "keeper_tasks_list"; "masc_status" ];
  check_violation "claim plus passive" [ "keeper_task_claim"; "keeper_tasks_list" ];
  check
    (option string)
    "task completion still satisfies owned task"
    None
    (KTD.actionable_tool_contract_violation_reason
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
            "actionable signal rejects no tools"
            `Quick
            test_actionable_tool_contract_flags_no_tools
        ; test_case
            "actionable signal preserves turn-gate context"
            `Quick
            test_actionable_tool_contract_preserves_turn_gate_context
        ; test_case
            "actionable signal rejects passive-only tools"
            `Quick
            test_actionable_tool_contract_flags_passive_only_tools
        ; test_case
            "actionable signal rejects claim context after ownership"
            `Quick
            test_actionable_tool_contract_rejects_claim_context_when_already_claimed
        ; test_case
            "actionable signal rejects stay_silent after ownership"
            `Quick
            test_actionable_tool_contract_rejects_stay_silent_when_already_claimed
        ] )
    ]
;;
