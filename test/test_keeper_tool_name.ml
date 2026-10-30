open Alcotest

let test_keeper_task_round_trip () =
  let name = Keeper_tooling.Name.to_string Keeper_tooling.Name.Task_create in
  check string "wire name" "keeper_task_create" name;
  check
    bool
    "typed parse"
    true
    (Keeper_tooling.Name.of_string name = Some Keeper_tooling.Name.Task_create)
;;

let () =
  run
    "Keeper_tooling.Name"
    [ ( "vocabulary"
      , [ test_case "keeper task round-trip" `Quick test_keeper_task_round_trip ] )
    ]
;;
