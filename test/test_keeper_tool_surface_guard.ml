open Alcotest
module KTO = Masc_mcp.Keeper_tool_observation
module Resolution = Masc_mcp.Keeper_tool_resolution
module Surface = Masc_mcp.Keeper_agent_tool_surface

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
       ~allowed_tool_names:[ "Execute"; "Read" ]
       ~tool_names:[ "tool_execute"; "tool_read_file" ])
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
        schema-visible tool. Use Execute instead.")
    (Resolution.public_alias_guidance_for_internal_call
       ~visible_tool_names:[ "Execute"; "Read" ]
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
       schema-visible tool. Use Edit instead."
  in
  check
    (option string)
    "visible edit alias"
    expected
    (Resolution.public_alias_guidance_for_internal_call
       ~visible_tool_names:[ "Edit" ]
       "tool_edit_file")
;;

let test_public_alias_guidance_reports_alias_not_visible () =
  check
    (option string)
    "alias not visible"
    (Some
       "tool_execute is an internal keeper implementation tool name, not a \
        schema-visible tool. No public alias for it is visible in this turn; do \
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
       ~unexpected_tool_names:[ "Execute"; "Skill"; "Read" ]
       ~tool_names:[ "Execute"; "Skill"; "Read" ])
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
            "internal edit prefers visible Edit alias"
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
    ]
;;
