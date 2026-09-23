(* The pinned world-state briefing must be sized over the candidates the
   turn's walk may dispatch. [test_keeper_turn_driver_failover] pins what
   [world_state_briefing_budget_bytes] and [briefing_candidates_for_turn]
   answer; these tests pin that the turn actually hands their answer to the
   prompt builder. Before #38500 the turn sized the briefing from the lane
   head alone, and reverting to that, or to no budget, passed every
   behavioural test. *)

let unified_turn = "lib/keeper/keeper_unified_turn.ml"

let test_the_budget_binding_is_the_walk_sized_budget () =
  Alcotest.(check int)
    "context_budget_bytes is computed by world_state_briefing_budget_bytes"
    1
    (Ast_grep.count_calls_in_value_binding
       ~module_path:unified_turn
       ~binding_name:"context_budget_bytes"
       ~callee:"world_state_briefing_budget_bytes");
  Alcotest.(check int)
    "over the candidates briefing_candidates_for_turn names"
    1
    (Ast_grep.count_calls_in_value_binding
       ~module_path:unified_turn
       ~binding_name:"context_budget_bytes"
       ~callee:"briefing_candidates_for_turn")
;;

let test_every_prompt_build_receives_the_budget () =
  let builds =
    Ast_grep.count_calls
      ~module_path:unified_turn
      ~callee:"Keeper_unified_prompt.build_prompt"
  in
  Alcotest.(check bool) "the turn builds a prompt" true (builds > 0);
  Alcotest.(check int)
    "every build_prompt call passes context_budget_bytes"
    builds
    (Ast_grep.count_calls_with_label
       ~module_path:unified_turn
       ~callee:"Keeper_unified_prompt.build_prompt"
       ~label:"context_budget_bytes")
;;

let test_the_deferred_candidates_are_the_walks_own_list () =
  Alcotest.(check int)
    "a deferred hint is read through Keeper_turn_driver.deferred_runtime_ids, \
     the list the walk dispatches"
    1
    (Ast_grep.count_calls_in_value_binding
       ~module_path:unified_turn
       ~binding_name:"briefing_candidates_for_turn"
       ~callee:"Keeper_turn_driver.deferred_runtime_ids")
;;

let () =
  Alcotest.run
    "keeper_briefing_budget_wiring"
    [ ( "wiring"
      , [ Alcotest.test_case
            "the budget binding is the walk-sized budget"
            `Quick
            test_the_budget_binding_is_the_walk_sized_budget
        ; Alcotest.test_case
            "every prompt build receives the budget"
            `Quick
            test_every_prompt_build_receives_the_budget
        ; Alcotest.test_case
            "the deferred candidates are the walk's own list"
            `Quick
            test_the_deferred_candidates_are_the_walks_own_list
        ] )
    ]
;;
