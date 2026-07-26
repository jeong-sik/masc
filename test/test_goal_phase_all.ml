module GP = Goal_phase
open Alcotest

let test_phase_roundtrip () =
  List.iter
    (fun phase ->
       let encoded = GP.view_to_string phase in
       check bool ("phase " ^ encoded) true (GP.of_string encoded = Some phase))
    GP.all
;;

let test_phase_set () =
  let encoded = List.map GP.view_to_string GP.all in
  check
    (list string)
    "phase order"
    [ "executing"; "blocked"; "paused"; "completed"; "dropped" ]
    encoded
;;

let test_action_roundtrip () =
  List.iter
    (fun action ->
       let encoded = GP.action_to_string action in
       check bool ("action " ^ encoded) true (GP.action_of_string encoded = Some action))
    GP.all_actions
;;

let () =
  run
    "goal_phase_all"
    [ ( "phase"
      , [ test_case "round-trip" `Quick test_phase_roundtrip
        ; test_case "set and order" `Quick test_phase_set
        ] )
    ; "action", [ test_case "round-trip" `Quick test_action_roundtrip ]
    ]
