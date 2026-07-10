open Alcotest

let test_all_names_round_trip () =
  List.iter
    (fun tool ->
       let name = Keeper_tool_name.to_string tool in
       check bool name true (Keeper_tool_name.of_string name = Some tool))
    Keeper_tool_name.all
;;

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

let () =
  run
    "Keeper_tool_name"
    [ ( "vocabulary"
      , [ test_case "all names round-trip" `Quick test_all_names_round_trip ] )
    ; ( "board-write"
      , [ test_case "recognizes write surfaces" `Quick test_board_write_surface_names
        ; test_case
            "rejects non-write and unknown surfaces"
            `Quick
            test_non_write_board_surface_names
        ] )
    ]
;;
