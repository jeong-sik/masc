open Alcotest

module KTD = Masc_mcp.Keeper_tool_disclosure

let test_unexpected_tool_names_accepts_keeper_surface () =
  check (list string) "no unexpected tools" []
    (KTD.unexpected_tool_names
       ~allowed_tool_names:
         [ "keeper_task_claim"; "keeper_board_comment"; "extend_turns" ]
       ~tool_names:[ "keeper_task_claim"; "extend_turns" ])

let test_unexpected_tool_names_reports_foreign_surface () =
  check (list string) "foreign tools flagged"
    [ "Skill"; "Bash"; "Agent" ]
    (KTD.unexpected_tool_names
       ~allowed_tool_names:
         [ "keeper_task_claim"; "keeper_board_comment"; "extend_turns" ]
       ~tool_names:
         [ "keeper_task_claim"; "Skill"; "Bash"; "Skill"; "Agent" ])

let () =
  run "keeper_tool_surface_guard"
    [
      ( "surface_guard",
        [
          test_case "accepts keeper surface" `Quick
            test_unexpected_tool_names_accepts_keeper_surface;
          test_case "reports foreign surface" `Quick
            test_unexpected_tool_names_reports_foreign_surface;
        ] );
    ]
