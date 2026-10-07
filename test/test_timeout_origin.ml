open Masc

let test_standard_labels () =
  let cases =
    [ Timeout_origin.Spawn, "spawn"
    ; Timeout_origin.Command, "command"
    ]
  in
  List.iter
    (fun (origin, expected) ->
      Alcotest.(check string) expected expected (Timeout_origin.to_label origin))
    cases
;;

let () =
  Alcotest.run
    "timeout_origin"
    [ ( "typed origins"
      , [ Alcotest.test_case "standard labels" `Quick test_standard_labels ] )
    ]
;;
