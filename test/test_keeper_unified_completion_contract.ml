open Alcotest

module KTC = Masc_mcp.Keeper_tool_completion_contract
module KTO = Masc_mcp.Keeper_tool_observation
module KTP = Masc_mcp.Keeper_tool_progress

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
            "completion contract presence requires keeper-surface tool"
            `Quick
            test_validate_completion_contract_presence_requires_keeper_surface_tool
        ] )
    ]
;;
