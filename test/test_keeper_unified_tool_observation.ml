open Alcotest

module KTD = Masc_mcp.Keeper_tool_disclosure

let test_tool_usage_delta_uses_registry_counts () =
  let before = [ "keeper_board_post", 1; "keeper_fs_read", 0; "keeper_voice_agent", 2 ] in
  let after = [ "keeper_board_post", 1; "keeper_fs_read", 1; "keeper_voice_agent", 4 ] in
  check
    (list string)
    "delta tracks repeated calls"
    [ "keeper_fs_read"; "keeper_voice_agent"; "keeper_voice_agent" ]
    (KTD.tool_usage_delta ~before ~after)
;;

let test_tool_usage_delta_ignores_removed_tools () =
  let before = [ "keeper_board_post", 2; "keeper_voice_agent", 1 ] in
  let after = [ "keeper_board_post", 2 ] in
  check
    (list string)
    "no phantom tools when counts drop"
    []
    (KTD.tool_usage_delta ~before ~after)
;;

let test_merge_observed_tool_names_prefers_hook_without_double_counting () =
  let merged =
    KTD.merge_observed_tool_names
      ~hook_observed_tool_names:[ "keeper_bash"; "keeper_pr_create" ]
      ~registry_observed_tool_names:
        [ "keeper_bash"; "keeper_pr_create"; "keeper_board_post" ]
  in
  check
    (list string)
    "hook evidence plus registry-only tail"
    [ "keeper_bash"; "keeper_pr_create"; "keeper_board_post" ]
    merged
;;

let test_merge_observed_tool_names_preserves_extra_registry_repeats () =
  let merged =
    KTD.merge_observed_tool_names
      ~hook_observed_tool_names:[ "keeper_bash" ]
      ~registry_observed_tool_names:[ "keeper_bash"; "keeper_bash" ]
  in
  check
    (list string)
    "max count per observed source"
    [ "keeper_bash"; "keeper_bash" ]
    merged
;;

let test_merge_reported_and_observed_tool_names_preserves_synthetic_tools () =
  let merged =
    KTD.merge_reported_and_observed_tool_names
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
    KTD.final_keeper_tool_names
      ~reported_tool_names:[ "keeper_task_claim"; "Bash"; "Skill" ]
      ~observed_tool_names:[]
      ~allowed_tool_names:[ "keeper_task_claim"; "keeper_bash" ]
  in
  check
    (list string)
    "reported keeper tool plus alias preserved"
    [ "keeper_task_claim"; "keeper_bash" ]
    final_tools
;;

let test_final_keeper_tool_names_accepts_reported_mcp_keeper_tool () =
  let final_tools =
    KTD.final_keeper_tool_names
      ~reported_tool_names:[ "mcp__masc__masc_board_post"; "list_mcp_resources" ]
      ~observed_tool_names:[]
      ~allowed_tool_names:[ "keeper_board_post"; "keeper_bash" ]
  in
  check
    (list string)
    "reported MCP keeper tool preserved"
    [ "keeper_board_post" ]
    final_tools;
  check
    (option string)
    "reported execution tool satisfies actionable signal"
    None
    (KTD.actionable_tool_contract_violation_reason
       ~claim_context_allowed:true
       ~actionable_signal_context:true
       ~tool_names:final_tools)
;;

let test_requested_tool_names_seen_preserves_prior_turn_surface () =
  let seen =
    Masc_mcp.Keeper_run_tools.merge_requested_tool_names_seen
      ~seen:[]
      [ "keeper_board_curation_submit"; "keeper_board_post" ]
  in
  let seen =
    Masc_mcp.Keeper_run_tools.merge_requested_tool_names_seen
      ~seen
      [ "keeper_board_post"; "keeper_board_comment" ]
  in
  check
    (list string)
    "run surface keeps prior-turn tools"
    [ "keeper_board_curation_submit"; "keeper_board_post"; "keeper_board_comment" ]
    seen;
  check
    (list string)
    "prior-turn observed tool remains expected for run-level validation"
    []
    (KTD.unexpected_tool_names
       ~allowed_tool_names:seen
       ~tool_names:[ "keeper_board_curation_submit" ]);
  check
    (list string)
    "last-turn-only surface would have false-positive unexpected tool"
    [ "keeper_board_curation_submit" ]
    (KTD.unexpected_tool_names
       ~allowed_tool_names:[ "keeper_board_post"; "keeper_board_comment" ]
       ~tool_names:[ "keeper_board_curation_submit" ])
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
            "final keeper tool names accept reported MCP keeper tool"
            `Quick
            test_final_keeper_tool_names_accepts_reported_mcp_keeper_tool
        ; test_case
            "requested tool names seen preserves prior turn surface"
            `Quick
            test_requested_tool_names_seen_preserves_prior_turn_surface
        ] )
    ]
;;
