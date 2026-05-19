open Alcotest

module KTD = Masc_mcp.Keeper_tool_disclosure

let required_tool_call name input : Agent_sdk.Completion_contract.tool_call =
  { name; input; tool = None }
;;

let satisfies_required_tool name input =
  Result.is_ok (KTD.required_tool_satisfaction (required_tool_call name input))
;;

let satisfies_explicit_required_tool ~required_tool_names name input =
  Result.is_ok
    (KTD.required_tool_satisfaction_for_required_names
       ~required_tool_names
       (required_tool_call name input))
;;

let test_required_tool_satisfaction_rejects_passive_tools () =
  check bool "global masc_status remains passive" false
    (satisfies_required_tool "masc_status" (`Assoc []));
  check bool "keeper_tasks_list cannot satisfy required-action contract" false
    (satisfies_required_tool "keeper_tasks_list" (`Assoc []));
  check bool "keeper_context_status cannot satisfy required-action contract" false
    (satisfies_required_tool "keeper_context_status" (`Assoc []));
  check bool "keeper_memory_search cannot satisfy required-action contract" false
    (satisfies_required_tool "keeper_memory_search" (`Assoc []));
  check bool "keeper_tool_search cannot satisfy required-action contract" false
    (satisfies_required_tool "keeper_tool_search" (`Assoc []));
  check bool "keeper_board_get cannot satisfy required-action contract" false
    (satisfies_required_tool "keeper_board_get" (`Assoc []));
  check bool "keeper_board_list cannot satisfy required-action contract" false
    (satisfies_required_tool "keeper_board_list" (`Assoc []));
  check bool "keeper_time_now cannot satisfy required-action contract" false
    (satisfies_required_tool "keeper_time_now" (`Assoc []));
  check bool "keeper_memory_search remains passive progress" true
    (KTD.is_passive_status_tool_name "keeper_memory_search");
  check bool "keeper_memory_search is not execution progress" false
    (KTD.is_execution_progress_tool_name "keeper_memory_search");
  check bool "keeper_stay_silent satisfies as completion" true
    (satisfies_required_tool "keeper_stay_silent" (`Assoc []));
  check bool "Read alias cannot satisfy required-action contract" false
    (satisfies_required_tool "Read" (`Assoc []));
  check bool "Grep alias cannot satisfy required-action contract" false
    (satisfies_required_tool "Grep" (`Assoc []));
  check bool "Read alias remains passive progress" true
    (KTD.is_passive_status_tool_name "Read");
  check bool "Grep alias remains passive progress" true
    (KTD.is_passive_status_tool_name "Grep");
  check bool "read-only gh shell is passive" false
    (satisfies_required_tool
       "keeper_shell"
       (`Assoc [ "op", `String "gh"; "cmd", `String "pr view 123" ]))
;;

let test_required_tool_satisfaction_accepts_mutating_tools () =
  check bool "keeper_task_claim mutates" true
    (satisfies_required_tool "keeper_task_claim" (`Assoc []));
  check bool "Write alias mutates" true (satisfies_required_tool "Write" (`Assoc []));
  check bool "mutating gh shell satisfies" true
    (satisfies_required_tool
       "keeper_shell"
       (`Assoc [ "op", `String "gh"; "cmd", `String "pr comment 123 --body ok" ]));
  check bool "fresh worktree create result is material progress" true
    (KTD.tool_result_has_material_progress
       ~tool_name:"masc_worktree_create"
       ~output_text:"Worktree created:\n  Path: /tmp/wt");
  check bool "already-existing worktree result is idempotent no-progress" false
    (KTD.tool_result_has_material_progress
       ~tool_name:"masc_worktree_create"
       ~output_text:"Worktree already exists:\n  Path: /tmp/wt")
;;

let test_explicit_required_tool_satisfaction_accepts_named_passive_tool () =
  check bool "generic masc_web_search remains passive" false
    (satisfies_required_tool "masc_web_search" (`Assoc []));
  check bool "explicit masc_web_search satisfies required contract" true
    (satisfies_explicit_required_tool
       ~required_tool_names:[ "masc_web_search" ]
       "masc_web_search"
       (`Assoc []));
  check bool "explicit required list canonicalizes WebSearch alias" true
    (satisfies_explicit_required_tool
       ~required_tool_names:[ "masc_web_search" ]
       "WebSearch"
       (`Assoc []));
  check bool "unlisted passive tool still rejected" false
    (satisfies_explicit_required_tool
       ~required_tool_names:[ "keeper_bash" ]
       "masc_web_search"
       (`Assoc []))
;;

let test_turn_required_tool_satisfaction_keeps_generic_presence_separate () =
  check bool "generic required-action predicate still rejects passive board read" false
    (satisfies_required_tool "keeper_board_get" (`Assoc []));
  check bool
    "turn-level generic gate accepts passive tool presence for post-run classification" true
    (Result.is_ok
       (KTD.required_tool_satisfaction_for_turn
          ~required_tool_names:[]
          (required_tool_call "keeper_board_get" (`Assoc []))));
  check bool "explicit required action still rejects unrelated passive tool" false
    (Result.is_ok
       (KTD.required_tool_satisfaction_for_turn
          ~required_tool_names:[ "keeper_bash" ]
          (required_tool_call "keeper_board_get" (`Assoc []))));
  check bool "explicit named passive tool remains allowed" true
    (Result.is_ok
       (KTD.required_tool_satisfaction_for_turn
          ~required_tool_names:[ "keeper_board_get" ]
          (required_tool_call "keeper_board_get" (`Assoc []))))
;;

let test_required_tool_satisfaction_includes_satisfying_tools_hint () =
  let base_error =
    KTD.required_tool_satisfaction (required_tool_call "masc_status" (`Assoc []))
  in
  check string "base rejection has no suggestion suffix"
    "tool 'masc_status' is read-only/passive and cannot satisfy a required-tool contract"
    (Result.get_error base_error);
  let hinted_error =
    KTD.required_tool_satisfaction
      ~satisfying_tools:[ "keeper_board_post"; "keeper_board_comment" ]
      (required_tool_call "masc_status" (`Assoc []))
  in
  check string "hinted rejection includes satisfying tools"
    "tool 'masc_status' is read-only/passive and cannot satisfy a required-tool \
     contract. Call one of these instead: [keeper_board_post; keeper_board_comment]"
    (Result.get_error hinted_error);
  check bool "mutating tool still satisfies regardless of satisfying_tools" true
    (Result.is_ok
       (KTD.required_tool_satisfaction
          ~satisfying_tools:[ "keeper_board_post" ]
          (required_tool_call "keeper_bash"
             (`Assoc [ "op", `String "echo"; "cmd", `String "hello" ]))));
  let empty_hint_error =
    KTD.required_tool_satisfaction
      ~satisfying_tools:[]
      (required_tool_call "keeper_tasks_list" (`Assoc []))
  in
  check string "empty satisfying_tools uses base message"
    "tool 'keeper_tasks_list' is read-only/passive and cannot satisfy a required-tool \
     contract"
    (Result.get_error empty_hint_error);
  let turn_hinted =
    KTD.required_tool_satisfaction_for_turn
      ~satisfying_tools:[ "keeper_task_claim" ]
      ~required_tool_names:[ "keeper_bash" ]
      (required_tool_call "masc_status" (`Assoc []))
  in
  check string "turn-level rejection forwards satisfying_tools hint"
    "tool 'masc_status' is read-only/passive and cannot satisfy a required-tool \
     contract. Call one of these instead: [keeper_task_claim]"
    (Result.get_error turn_hinted)
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
  let multi =
    Surface.satisfying_tools_for_turn
      ~turn_affordances:[ "reply_in_room"; "board_post_or_comment" ]
      ~allowed_tool_names:
        [ "keeper_board_post"; "keeper_board_comment"; "masc_broadcast"; "masc_keeper_msg" ]
  in
  List.iter
    (fun t -> check bool ("tool in multi-affordance result: " ^ t) true (List.mem t multi))
    [ "keeper_board_post"; "keeper_board_comment"; "masc_keeper_msg"; "masc_broadcast" ];
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
            "required tool predicate handles passive tools"
            `Quick
            test_required_tool_satisfaction_rejects_passive_tools
        ; test_case
            "required tool predicate accepts mutating tools"
            `Quick
            test_required_tool_satisfaction_accepts_mutating_tools
        ; test_case
            "explicit required tool predicate accepts named passive tool"
            `Quick
            test_explicit_required_tool_satisfaction_accepts_named_passive_tool
        ; test_case
            "turn required tool predicate separates presence from progress"
            `Quick
            test_turn_required_tool_satisfaction_keeps_generic_presence_separate
        ; test_case
            "required tool satisfaction includes satisfying tools hint"
            `Quick
            test_required_tool_satisfaction_includes_satisfying_tools_hint
        ; test_case
            "satisfying_tools_for_turn computes from affordances"
            `Quick
            test_satisfying_tools_for_turn_computes_from_affordances
        ] )
    ]
;;
