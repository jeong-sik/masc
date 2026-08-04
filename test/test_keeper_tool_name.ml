open Alcotest

let test_keeper_task_round_trip () =
  let name = Keeper_tool_name.to_string Keeper_tool_name.Task_create in
  check string "wire name" "keeper_task_create" name;
  check
    bool
    "typed parse"
    true
    (Keeper_tool_name.of_string name = Some Keeper_tool_name.Task_create)
;;

let () =
  run
    "Keeper_tool_name"
    [ ( "vocabulary"
      , [ test_case "keeper task round-trip" `Quick test_keeper_task_round_trip ] )
    ]
;;
