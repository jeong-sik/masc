open Alcotest

module Axis = Masc.Keeper_tool_capability_axis

let check_support capability name expected =
  check bool name expected (Axis.supports capability name)
;;

let test_claim_task_supports_keeper_and_public_projection () =
  check_support Axis.Claim_task "keeper_task_claim" true;
  check_support Axis.Claim_task "keeper_tasks_list" false
;;

let test_board_activity_supports_keeper_and_public_projection () =
  check_support Axis.Board_activity "keeper_board_post" true;
  check_support Axis.Board_activity "keeper_board_comment" true;
  check_support Axis.Board_activity "masc_broadcast" true;
  check_support Axis.Board_activity "mcp__masc__masc_broadcast" true;
  check_support Axis.Board_activity "masc_keeper_msg" true;
  check_support Axis.Board_activity "keeper_board_list" false
;;

let () =
  run
    "keeper_tool_capability_axis"
    [ ( "supports"
      , [ test_case
            "claim task supports keeper and public projection names"
            `Quick
            test_claim_task_supports_keeper_and_public_projection
        ; test_case
            "board activity supports keeper and public projection names"
            `Quick
            test_board_activity_supports_keeper_and_public_projection
        ] )
    ]
;;
