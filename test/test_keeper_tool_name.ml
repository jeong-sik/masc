open Alcotest

let test_keeper_msg_round_trip () =
  let name = Keeper_tool_name.to_string Keeper_tool_name.Keeper_msg in
  check string "wire name" "masc_keeper_msg" name;
  check
    bool
    "typed parse"
    true
    (Keeper_tool_name.of_string name = Some Keeper_tool_name.Keeper_msg)
;;

let () =
  run
    "Keeper_tool_name"
    [ ( "vocabulary"
      , [ test_case "keeper_msg round-trip" `Quick test_keeper_msg_round_trip ] )
    ]
;;
