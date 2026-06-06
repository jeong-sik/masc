open Alcotest

let test_board_write_surface_names () =
  List.iter
    (fun name ->
       check bool name true (Keeper_tool_name.is_board_write_surface_name name))
    [ "keeper_board_post"
    ; "keeper_board_comment"
    ; "keeper_board_vote"
    ; "keeper_board_curation_submit"
    ; "masc_board_post"
    ; "masc_board_comment"
    ; "masc_board_vote"
    ; "masc_board_curation_submit"
    ; "mcp__masc__keeper_board_post"
    ; "mcp__masc__masc_board_post"
    ]
;;

let test_non_write_board_surface_names () =
  List.iter
    (fun name ->
       check bool name false (Keeper_tool_name.is_board_write_surface_name name))
    [ "keeper_board_get"
    ; "keeper_board_list"
    ; "keeper_board_search"
    ; "keeper_board_comment_vote"
    ; "masc_board_get"
    ; "masc_board_list"
    ; "masc_board_comment_vote"
    ; "tool_execute"
    ; "unknown"
    ]
;;

let test_state_report_name_round_trips () =
  check
    (option (testable Keeper_tool_name.pp ( = )))
    "of_string"
    (Some Keeper_tool_name.State_report)
    (Keeper_tool_name.of_string "keeper_report_state");
  check
    string
    "to_string"
    "keeper_report_state"
    (Keeper_tool_name.to_string Keeper_tool_name.State_report);
  check
    bool
    "not board write"
    false
    (Keeper_tool_name.is_board_write_surface_name "keeper_report_state")
;;

let () =
  run
    "Keeper_tool_name"
    [ ( "board-write"
      , [ test_case "recognizes write surfaces" `Quick test_board_write_surface_names
        ; test_case
            "rejects non-write and unknown surfaces"
            `Quick
            test_non_write_board_surface_names
        ; test_case
            "state report name round-trips"
            `Quick
            test_state_report_name_round_trips
        ] )
    ]
;;
