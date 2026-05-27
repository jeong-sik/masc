open Alcotest
module KTO = Masc_mcp.Keeper_tool_observation
module Resolution = Masc_mcp.Keeper_tool_resolution
module KTS = Masc_mcp.Keeper_tool_selection

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

let test_unexpected_tool_names_flags_known_tool_outside_selected_surface () =
  check
    (list string)
    "known keeper tool outside selected surface is unexpected"
    [ "keeper_board_list" ]
    (KTO.unexpected_tool_names
       ~allowed_tool_names:[ "keeper_task_claim"; "keeper_board_post" ]
       ~tool_names:[ "keeper_board_list" ])
;;

let test_unexpected_tool_names_accepts_public_alias_surface () =
  check
    (list string)
    "public alias accepts internal handler"
    []
    (KTO.unexpected_tool_names
       ~allowed_tool_names:[ "Execute"; "ReadFile"; "masc_board_post" ]
       ~tool_names:[ "tool_execute"; "tool_read_file"; "keeper_board_post" ])
;;

let test_final_keeper_tool_names_accepts_public_alias_surface () =
  check
    (list string)
    "public alias keeps canonical internal tool"
    [ "tool_execute" ]
    (KTO.final_keeper_tool_names
       ~reported_tool_names:[ "mcp__masc__Execute" ]
       ~observed_tool_names:[ "tool_execute" ]
       ~allowed_tool_names:[ "Execute" ])
;;

let test_public_alias_guidance_blocks_internal_bash () =
  check
    (option string)
    "internal bash guidance"
    (Some
       "tool_execute is an internal keeper implementation tool name, not a \
        model-facing tool. Use Execute instead.")
    (Resolution.public_alias_guidance_for_internal_call
       ~visible_tool_names:[ "Execute"; "ReadFile" ]
       "tool_execute")
;;

let test_public_alias_guidance_ignores_public_execute () =
  check
    (option string)
    "public Execute is already model-facing"
    None
    (Resolution.public_alias_guidance_for_internal_call
       ~visible_tool_names:[ "Execute" ]
       "Execute")
;;

let test_public_alias_guidance_prefers_visible_edit_alias () =
  let expected =
    Some
      "tool_edit_file is an internal keeper implementation tool name, not a \
       model-facing tool. Use EditFile instead."
  in
  check
    (option string)
    "visible edit alias"
    expected
    (Resolution.public_alias_guidance_for_internal_call
       ~visible_tool_names:[ "EditFile" ]
       "tool_edit_file")
;;

let test_public_alias_guidance_reports_alias_not_visible () =
  check
    (option string)
    "alias not visible"
    (Some
       "tool_execute is an internal keeper implementation tool name, not a \
        model-facing tool. No public alias for it is visible in this turn; do \
        not invent internal tool names. Wait for a visible tool or report the \
        blocker. Public alias: Execute.")
    (Resolution.public_alias_guidance_for_internal_call
       ~visible_tool_names:[ "keeper_tasks_list" ]
       "tool_execute")
;;

let test_final_keeper_tool_names_drops_known_tool_outside_selected_surface () =
  check
    (list string)
    "known keeper tool outside selected surface is not accepted as work"
    []
    (KTO.final_keeper_tool_names
       ~reported_tool_names:[ "mcp__masc__keeper_board_list" ]
       ~observed_tool_names:[ "keeper_board_list" ]
       ~allowed_tool_names:[ "keeper_task_claim"; "keeper_board_post" ])
;;

(* #8471 partial tolerance: mixed turn (valid + unexpected) must not
   hard-fail — the valid tool call is real work and should survive. *)
let test_has_valid_tool_call_true_when_mixed () =
  check
    bool
    "mixed turn keeps valid tool call"
    true
    (KTO.has_valid_tool_call
       ~unexpected_tool_names:[ "Execute"; "Skill" ]
       ~tool_names:[ "keeper_task_claim"; "Execute"; "Skill" ])
;;

(* Pure hallucination: every call is outside the surface — no valid
   work in this turn, so keeper_agent_run correctly hard-fails. *)
let test_has_valid_tool_call_false_when_all_unexpected () =
  check
    bool
    "pure hallucination turn has no valid tool"
    false
    (KTO.has_valid_tool_call
       ~unexpected_tool_names:[ "Execute"; "Skill"; "ReadFile" ]
       ~tool_names:[ "Execute"; "Skill"; "ReadFile" ])
;;

(* Empty turn (text-only response, no tool calls): has_valid returns
   false. The caller's outer `unexpected_tool_names <> []` guard still
   prevents this case from being treated as a partial-tolerance success. *)
let test_has_valid_tool_call_false_when_empty () =
  check
    bool
    "empty tool list returns false"
    false
    (KTO.has_valid_tool_call ~unexpected_tool_names:[] ~tool_names:[])
;;

(* --- contract_enforcement_filter tests --- *)

(* Use real canonical tool names. Passive_status tools must have
   Tool_catalog.effect_domain = Some Read_only so classify_tool_progress
   classifies them through catalog-backed capabilities. *)

let passive_tool = "keeper_tasks_list"
let passive_tool_alt = "keeper_context_status"
let execution_tool = "keeper_task_claim"
let completion_tool = "keeper_stay_silent"
let claim_tool = "masc_claim_next"
let mixed_tools = [ passive_tool; execution_tool; completion_tool; claim_tool ]

(* Streak below threshold: no filtering regardless of signal. *)
let test_contract_filter_below_threshold () =
  check
    (list string)
    "all tools preserved"
    mixed_tools
    (KTS.contract_enforcement_filter
       ~passive_streak:2
       ~streak_threshold:3
       ~actionable_signal:true
       mixed_tools)
;;

(* At threshold but no actionable signal: no filtering. *)
let test_contract_filter_no_signal () =
  check
    (list string)
    "all tools preserved"
    mixed_tools
    (KTS.contract_enforcement_filter
       ~passive_streak:5
       ~streak_threshold:3
       ~actionable_signal:false
       mixed_tools)
;;

(* At threshold WITH actionable signal: passive tools stripped. *)
let test_contract_filter_strips_passive () =
  let filtered =
    KTS.contract_enforcement_filter
      ~passive_streak:5
      ~streak_threshold:3
      ~actionable_signal:true
      mixed_tools
  in
  check bool "passive tool removed" false (List.mem passive_tool filtered);
  check bool "execution preserved" true (List.mem execution_tool filtered);
  check bool "completion preserved" true (List.mem completion_tool filtered);
  check bool "claim preserved" true (List.mem claim_tool filtered);
  check int "3 tools remain" 3 (List.length filtered)
;;

(* Only passive tools in input: filter returns empty. *)
let test_contract_filter_all_passive () =
  check
    (list string)
    "empty result"
    []
    (KTS.contract_enforcement_filter
       ~passive_streak:5
       ~streak_threshold:3
       ~actionable_signal:true
       [ passive_tool; passive_tool_alt ])
;;

(* Empty input: empty output. *)
let test_contract_filter_empty_input () =
  check
    (list string)
    "empty in empty out"
    []
    (KTS.contract_enforcement_filter
       ~passive_streak:5
       ~streak_threshold:3
       ~actionable_signal:true
       [])
;;

let () =
  run
    "keeper_tool_surface_guard"
    [ ( "surface_guard"
      , [ test_case
            "accepts keeper surface"
            `Quick
            test_unexpected_tool_names_accepts_keeper_surface
        ; test_case
            "reports foreign surface"
            `Quick
            test_unexpected_tool_names_reports_foreign_surface
        ; test_case
            "flags known tool outside selected surface"
            `Quick
            test_unexpected_tool_names_flags_known_tool_outside_selected_surface
        ; test_case
            "accepts public alias surface"
            `Quick
            test_unexpected_tool_names_accepts_public_alias_surface
        ; test_case
            "final names accept public alias surface"
            `Quick
            test_final_keeper_tool_names_accepts_public_alias_surface
        ; test_case
            "internal bash receives public alias guidance"
            `Quick
            test_public_alias_guidance_blocks_internal_bash
        ; test_case
            "public Execute does not receive alias guidance"
            `Quick
            test_public_alias_guidance_ignores_public_execute
        ; test_case
            "internal edit prefers visible EditFile alias"
            `Quick
            test_public_alias_guidance_prefers_visible_edit_alias
        ; test_case
            "internal alias reports when public alias is not visible"
            `Quick
            test_public_alias_guidance_reports_alias_not_visible
        ; test_case
            "final names drop known tool outside selected surface"
            `Quick
            test_final_keeper_tool_names_drops_known_tool_outside_selected_surface
        ] )
    ; ( "partial_tolerance"
      , [ test_case
            "mixed turn keeps valid call"
            `Quick
            test_has_valid_tool_call_true_when_mixed
        ; test_case
            "pure hallucination has no valid"
            `Quick
            test_has_valid_tool_call_false_when_all_unexpected
        ; test_case
            "empty tool list returns false"
            `Quick
            test_has_valid_tool_call_false_when_empty
        ] )
    ; ( "contract_enforcement_filter"
      , [ test_case
            "below threshold: no filtering"
            `Quick
            test_contract_filter_below_threshold
        ; test_case "no signal: no filtering" `Quick test_contract_filter_no_signal
        ; test_case
            "strips passive at threshold with signal"
            `Quick
            test_contract_filter_strips_passive
        ; test_case "all passive: returns empty" `Quick test_contract_filter_all_passive
        ; test_case "empty input: empty output" `Quick test_contract_filter_empty_input
        ] )
    ]
;;
