open Alcotest

module KTO = Masc_mcp.Keeper_tool_observation
module KTP = Masc_mcp.Keeper_tool_progress

let test_passive_tool_classification () =
  check bool "keeper_memory_search remains passive progress" true
    (KTP.is_passive_status_tool_name "keeper_memory_search");
  check bool "keeper_memory_search is not execution progress" false
    (KTP.is_execution_progress_tool_name "keeper_memory_search");
  check bool "Read alias remains passive progress" true
    (KTP.is_passive_status_tool_name "Read");
  check bool "Grep alias remains passive progress" true
    (KTP.is_passive_status_tool_name "Grep");
  check bool "WebSearch alias remains passive progress" true
    (KTP.is_passive_status_tool_name "WebSearch")
;;

let test_mutating_tool_classification () =
  check bool "Write alias is execution progress" true
    (KTP.is_execution_progress_tool_name "Write");
  check bool "mcp-prefixed Write alias is execution progress" true
    (KTP.is_execution_progress_tool_name "mcp__masc__Write")
;;

let test_material_progress_detection () =
  check bool "fresh worktree create result is material progress" true
    (KTO.tool_result_has_material_progress
       ~tool_name:"tool_execute"
       ~output_text:"Worktree created:\n  Path: /tmp/wt");
  check bool "already-existing worktree result is idempotent no-progress" false
    (KTO.tool_result_has_material_progress
       ~tool_name:"tool_execute"
       ~output_text:"Worktree already exists:\n  Path: /tmp/wt")
;;

let test_satisfying_tools_for_turn_computes_from_affordances () =
  let module Surface = Masc_mcp.Keeper_agent_tool_surface in
  let tools =
    Surface.satisfying_tools_for_turn
      ~turn_affordances:[ "board_post_or_comment" ]
      ~allowed_tool_names:
        [ "keeper_board_post"; "keeper_board_comment"; "masc_broadcast"; "masc_status" ]
  in
  check
    (list string)
    "board_post_or_comment returns satisfying tools from allowed surface"
    [ "keeper_board_post"; "keeper_board_comment"; "masc_broadcast" ]
    tools;
  let partial =
    Surface.satisfying_tools_for_turn
      ~turn_affordances:[ "task_claim" ]
      ~allowed_tool_names:[ "masc_claim_next"; "masc_status" ]
  in
  check (list string) "task_claim returns only allowed subset" [ "masc_claim_next" ] partial;
  let empty =
    Surface.satisfying_tools_for_turn
      ~turn_affordances:[ "unknown_affordance" ]
      ~allowed_tool_names:[ "keeper_board_post" ]
  in
  check (list string) "unknown affordance yields empty" [] empty
;;

let () =
  run
    "keeper_unified_required_tools"
    [ ( "required_tools"
      , [ test_case
            "passive tool classification"
            `Quick
            test_passive_tool_classification
        ; test_case
            "mutating tool classification"
            `Quick
            test_mutating_tool_classification
        ; test_case
            "material progress detection"
            `Quick
            test_material_progress_detection
        ; test_case
            "satisfying_tools_for_turn computes from affordances"
            `Quick
            test_satisfying_tools_for_turn_computes_from_affordances
        ] )
    ]
;;
