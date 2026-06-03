open Alcotest

module KTO = Masc.Keeper_tool_observation

let test_tool_usage_delta_uses_registry_counts () =
  let before = [ "keeper_board_post", 1; "tool_read_file", 0; "keeper_voice_agent", 2 ] in
  let after = [ "keeper_board_post", 1; "tool_read_file", 1; "keeper_voice_agent", 4 ] in
  check
    (list string)
    "delta tracks repeated calls"
    [ "tool_read_file"; "keeper_voice_agent"; "keeper_voice_agent" ]
    (KTO.tool_usage_delta ~before ~after)
;;

let test_tool_usage_delta_ignores_removed_tools () =
  let before = [ "keeper_board_post", 2; "keeper_voice_agent", 1 ] in
  let after = [ "keeper_board_post", 2 ] in
  check
    (list string)
    "no phantom tools when counts drop"
    []
    (KTO.tool_usage_delta ~before ~after)
;;

let test_merge_observed_tool_names_prefers_hook_without_double_counting () =
  let merged =
    KTO.merge_observed_tool_names
      ~hook_observed_tool_names:[ "tool_execute"; "tool_execute" ]
      ~registry_observed_tool_names:
        [ "tool_execute"; "tool_execute"; "keeper_board_post" ]
  in
  check
    (list string)
    "hook evidence plus registry-only tail"
    [ "tool_execute"; "tool_execute"; "keeper_board_post" ]
    merged
;;

let test_merge_observed_tool_names_preserves_extra_registry_repeats () =
  let merged =
    KTO.merge_observed_tool_names
      ~hook_observed_tool_names:[ "tool_execute" ]
      ~registry_observed_tool_names:[ "tool_execute"; "tool_execute" ]
  in
  check
    (list string)
    "max count per observed source"
    [ "tool_execute"; "tool_execute" ]
    merged
;;

let test_merge_reported_and_observed_tool_names_preserves_synthetic_tools () =
  let merged =
    KTO.merge_reported_and_observed_tool_names
      ~reported_tool_names:[ "keeper_board_post" ]
      ~observed_tool_names:[ "keeper_voice_agent"; "keeper_voice_agent" ]
  in
  check
    (list string)
    "observed dispatch plus synthetic tool"
    [ "keeper_voice_agent"; "keeper_voice_agent"; "keeper_board_post" ]
    merged
;;

let test_final_keeper_tool_names_falls_back_to_reported_tool_use () =
  let final_tools =
    KTO.final_keeper_tool_names
      ~reported_tool_names:[ "keeper_task_claim"; "Execute"; "Skill" ]
      ~observed_tool_names:[]
      ~allowed_tool_names:[ "keeper_task_claim"; "tool_execute" ]
  in
  check
    (list string)
    "reported keeper tool plus alias preserved"
    [ "keeper_task_claim"; "tool_execute" ]
    final_tools
;;

let test_final_keeper_tool_names_ignores_legacy_mcp_alias () =
  let final_tools =
    KTO.final_keeper_tool_names
      ~reported_tool_names:[ "mcp__masc__masc_board_post"; "list_mcp_resources" ]
      ~observed_tool_names:[]
      ~allowed_tool_names:[ "keeper_board_post"; "tool_execute" ]
  in
  check
    (list string)
    "legacy MCP-prefixed keeper alias ignored"
    []
    final_tools
;;

let () =
  run
    "keeper_unified_tool_observation"
    [ ( "tool_observation"
      , [ test_case
            "tool usage delta uses registry counts"
            `Quick
            test_tool_usage_delta_uses_registry_counts
        ; test_case
            "tool usage delta ignores removed tools"
            `Quick
            test_tool_usage_delta_ignores_removed_tools
        ; test_case
            "merge observed tool names uses hook evidence"
            `Quick
            test_merge_observed_tool_names_prefers_hook_without_double_counting
        ; test_case
            "merge observed tool names keeps extra registry repeats"
            `Quick
            test_merge_observed_tool_names_preserves_extra_registry_repeats
        ; test_case
            "merge observed and synthetic tool names"
            `Quick
            test_merge_reported_and_observed_tool_names_preserves_synthetic_tools
        ; test_case
            "final keeper tool names fall back to reported tools"
            `Quick
            test_final_keeper_tool_names_falls_back_to_reported_tool_use
        ; test_case
            "final keeper tool names ignore legacy MCP keeper alias"
            `Quick
            test_final_keeper_tool_names_ignores_legacy_mcp_alias
        ] )
    ]
;;
