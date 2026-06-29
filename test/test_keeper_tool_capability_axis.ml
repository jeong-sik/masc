open Alcotest

module Axis = Masc.Keeper_tool_capability_axis
module Resolution = Masc.Keeper_tool_descriptor_resolution
module Tool_catalog = Tool_catalog

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

let test_polling_read_supports_descriptor_projection () =
  check bool "msg_result is descriptor-projected polling read" true
    (List.mem "masc_keeper_msg_result" Axis.polling_read_tool_names);
  check_support Axis.Polling_read "masc_keeper_msg_result" true;
  check_support Axis.Polling_read "mcp__masc__masc_keeper_msg_result" true;
  check_support Axis.Polling_read "keeper_tasks_list" false
;;

let test_polling_read_projection_is_descriptor_read_only () =
  List.iter
    (fun tool_name ->
       check (option bool)
         (tool_name ^ " readonly descriptor policy")
         (Some true)
         (Resolution.readonly_for_tool_call ~tool_name ~input:(`Assoc []));
       check bool
         (tool_name ^ " effect domain is read-only")
         true
         (match Resolution.effect_domain_for_tool_name tool_name with
          | Some Tool_catalog.Read_only -> true
          | Some (Tool_catalog.Masc_workspace
                 | Tool_catalog.Playground_write
                 | Tool_catalog.Host_repo_write)
          | None -> false))
    Axis.polling_read_tool_names
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
        ; test_case
            "polling read supports descriptor projection names"
            `Quick
            test_polling_read_supports_descriptor_projection
        ; test_case
            "polling read projection is descriptor read-only"
            `Quick
            test_polling_read_projection_is_descriptor_read_only
        ] )
    ]
;;
