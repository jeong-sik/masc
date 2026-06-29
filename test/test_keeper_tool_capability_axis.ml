open Alcotest

module Axis = Masc.Keeper_tool_capability_axis
module Resolution = Masc.Keeper_tool_descriptor_resolution
module Progress = Masc.Keeper_tool_progress
module Tool_resolution = Masc.Keeper_tool_resolution
module Tool_catalog = Tool_catalog

let check_support capability name expected =
  check bool name expected (Axis.supports capability name)
;;

let is_execution name =
  match Progress.classify_tool_progress name with
  | Progress.Execution -> true
  | Progress.Passive_status | Progress.Claim_context | Progress.Completion -> false
;;

let check_execution name =
  check bool (name ^ " classifies as Execution (Board_activity)") true (is_execution name)
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

(* #22042 / RFC-0239 ground truth — a board/broadcast/keeper_msg turn must
   classify as Execution so the anti-thrash streak accrues, for *every*
   representation the runtime can present: the public MCP name, the
   mcp-prefixed name, and the internal canonical name that
   [Keeper_agent_result.tool_names_of_calls] produces via
   [Keeper_tool_resolution.canonical_tool_name]. Broadcast's registration is
   asymmetric (descriptor internal "keeper_broadcast" vs non-descriptor public
   "masc_broadcast" canonicalizing to itself), so both forms are exercised;
   keeper_msg is symmetric. Before the canonical-form fix the internal
   "keeper_broadcast" representation fell through to Passive_status. *)
let test_board_activity_classification_ground_truth () =
  check_execution "masc_broadcast";
  check_execution "mcp__masc__masc_broadcast";
  check_execution "keeper_broadcast";
  check_execution "masc_keeper_msg";
  check_execution "mcp__masc__masc_keeper_msg";
  check_execution "keeper_board_post";
  check_execution "keeper_board_comment";
  check bool "canonicalized public broadcast supports Board_activity" true
    (Axis.supports Axis.Board_activity (Tool_resolution.canonical_tool_name "masc_broadcast"));
  check bool "canonicalized internal broadcast supports Board_activity" true
    (Axis.supports Axis.Board_activity (Tool_resolution.canonical_tool_name "keeper_broadcast"))
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
            "board activity classification ground truth (#22042 all representations)"
            `Quick
            test_board_activity_classification_ground_truth
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
