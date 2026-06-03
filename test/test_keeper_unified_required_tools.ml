open Alcotest

module KTO = Masc_mcp.Keeper_tool_observation
module KTP = Masc_mcp.Keeper_tool_progress

let required_tool_call name input : Agent_sdk.Completion_contract.tool_call =
  { name; input; tool = None }
;;

let satisfies_required_tool name input =
  Result.is_ok (KTP.required_tool_satisfaction (required_tool_call name input))
;;

let test_required_tool_satisfaction_accepts_observation_tools () =
  check bool "global masc_status satisfies provider tool-use" true
    (satisfies_required_tool "masc_status" (`Assoc []));
  check bool "keeper_tasks_list satisfies provider tool-use" true
    (satisfies_required_tool "keeper_tasks_list" (`Assoc []));
  check bool "keeper_context_status satisfies provider tool-use" true
    (satisfies_required_tool "keeper_context_status" (`Assoc []));
  check bool "keeper_memory_search satisfies provider tool-use" true
    (satisfies_required_tool "keeper_memory_search" (`Assoc []));
  check bool "keeper_tool_search satisfies provider tool-use" true
    (satisfies_required_tool "keeper_tool_search" (`Assoc []));
  check bool "keeper_board_get satisfies provider tool-use" true
    (satisfies_required_tool "keeper_board_get" (`Assoc []));
  check bool "keeper_board_list satisfies provider tool-use" true
    (satisfies_required_tool "keeper_board_list" (`Assoc []));
  check bool "keeper_time_now satisfies provider tool-use" true
    (satisfies_required_tool "keeper_time_now" (`Assoc []));
  check bool "keeper_memory_search remains passive progress" true
    (KTP.is_passive_status_tool_name "keeper_memory_search");
  check bool "keeper_memory_search is not execution progress" false
    (KTP.is_execution_progress_tool_name "keeper_memory_search");
  check bool "keeper_stay_silent satisfies as completion" true
    (satisfies_required_tool "keeper_stay_silent" (`Assoc []));
  check bool "Read alias satisfies provider tool-use" true
    (satisfies_required_tool "Read" (`Assoc []));
  check bool "Grep alias satisfies provider tool-use" true
    (satisfies_required_tool "Grep" (`Assoc []));
  check bool "mcp-prefixed Grep satisfies provider tool-use" true
    (satisfies_required_tool "mcp__masc__Grep" (`Assoc []));
  check bool "WebSearch alias satisfies provider tool-use" true
    (satisfies_required_tool "WebSearch" (`Assoc []));
  check bool "Read alias remains passive progress" true
    (KTP.is_passive_status_tool_name "Read");
  check bool "Grep alias remains passive progress" true
    (KTP.is_passive_status_tool_name "Grep");
  check bool "WebSearch alias remains passive progress" true
    (KTP.is_passive_status_tool_name "WebSearch");
  check bool "tool_search_files gh op satisfies provider tool-use" true
    (satisfies_required_tool
       "tool_search_files"
       (`Assoc [ "op", `String "gh"; "cmd", `String "pr view 123" ]))
;;

let test_required_tool_satisfaction_accepts_mutating_tools () =
  check bool "keeper_task_claim mutates" true
    (satisfies_required_tool "keeper_task_claim" (`Assoc []));
  check bool "Write alias mutates" true
    (satisfies_required_tool "Write" (`Assoc []));
  check bool "mcp-prefixed Write alias mutates" true
    (satisfies_required_tool "mcp__masc__Write" (`Assoc []));
  check bool "Write alias is execution progress" true
    (KTP.is_execution_progress_tool_name "Write");
  check bool "mcp-prefixed Write alias is execution progress" true
    (KTP.is_execution_progress_tool_name "mcp__masc__Write");
  check bool "mutating gh bash satisfies" true
    (satisfies_required_tool
       "tool_execute"
       (`Assoc [ "cmd", `String "gh pr comment 123 --body ok" ]));
  check bool "fresh worktree create result is material progress" true
    (KTO.tool_result_has_material_progress
       ~tool_name:"tool_execute"
       ~output_text:"Worktree created:\n  Path: /tmp/wt");
  check bool "already-existing worktree result is idempotent no-progress" false
    (KTO.tool_result_has_material_progress
       ~tool_name:"tool_execute"
       ~output_text:"Worktree already exists:\n  Path: /tmp/wt")
;;

let test_required_tool_satisfaction_ignores_satisfying_tools_hint () =
  check bool "base observation tool call satisfies provider tool-use" true
    (Result.is_ok
       (KTP.required_tool_satisfaction
          (required_tool_call "masc_status" (`Assoc []))));
  check bool "satisfying_tools hint does not turn observation into rejection" true
    (Result.is_ok
       (KTP.required_tool_satisfaction
          ~satisfying_tools:[ "keeper_board_post"; "keeper_board_comment" ]
          (required_tool_call "masc_status" (`Assoc []))));
  check bool "mutating tool still satisfies regardless of satisfying_tools" true
    (Result.is_ok
       (KTP.required_tool_satisfaction
          ~satisfying_tools:[ "keeper_board_post" ]
          (required_tool_call "tool_execute"
             (`Assoc [ "op", `String "echo"; "cmd", `String "hello" ]))));
  check bool "empty satisfying_tools still accepts observation tools" true
    (Result.is_ok
       (KTP.required_tool_satisfaction
          ~satisfying_tools:[]
          (required_tool_call "keeper_tasks_list" (`Assoc []))));
  check bool "passive hint path stays accepted" true
    (Result.is_ok
       (KTP.required_tool_satisfaction
          ~satisfying_tools:[ "keeper_task_claim" ]
          (required_tool_call "masc_status" (`Assoc []))))
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

let test_contract_violation_reason_extracts_oas_satisfying_tools () =
  let reason =
    "required tool contract unsatisfied: model called [masc_status], but no call \
     satisfied the required-tool predicate\n\
     Satisfying tools for this contract: [keeper_board_post, masc_broadcast]"
  in
  check
    (list string)
    "extract OAS satisfying tools"
    [ "keeper_board_post"; "masc_broadcast" ]
    (KTP.satisfying_tools_from_contract_violation_reason reason);
  check
    (list string)
    "dedupe and trim"
    [ "keeper_board_post"; "masc_broadcast" ]
    (KTP.satisfying_tools_from_contract_violation_reason
       "Satisfying tools for this contract: [ keeper_board_post, masc_broadcast, \
        keeper_board_post ]");
  check
    (list string)
    "missing hint"
    []
    (KTP.satisfying_tools_from_contract_violation_reason
       "required tool contract unsatisfied: model called []")
;;

let () =
  run
    "keeper_unified_required_tools"
    [ ( "required_tools"
      , [ test_case
            "required tool predicate accepts observation tools"
            `Quick
            test_required_tool_satisfaction_accepts_observation_tools
        ; test_case
            "required tool predicate accepts mutating tools"
            `Quick
            test_required_tool_satisfaction_accepts_mutating_tools
        ; test_case
            "required tool satisfaction ignores satisfying tools hint"
            `Quick
            test_required_tool_satisfaction_ignores_satisfying_tools_hint
        ; test_case
            "satisfying_tools_for_turn computes from affordances"
            `Quick
            test_satisfying_tools_for_turn_computes_from_affordances
        ; test_case
            "contract violation reason extracts OAS satisfying tools"
            `Quick
            test_contract_violation_reason_extracts_oas_satisfying_tools
        ] )
    ]
;;
