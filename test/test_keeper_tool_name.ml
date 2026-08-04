open Alcotest

let test_keeper_board_round_trip () =
  let name = Keeper_tool_name.to_string Keeper_tool_name.Board_post in
  check string "wire name" "keeper_board_post" name;
  check
    bool
    "typed parse"
    true
    (Keeper_tool_name.of_string name = Some Keeper_tool_name.Board_post)
;;

let () =
  run
    "Keeper_tool_name"
    [ ( "vocabulary"
      , [ test_case "keeper board round-trip" `Quick test_keeper_board_round_trip ] )
    ]
;;
