open Alcotest

module CB = Keeper_failure_circuit_breaker_types
module R = Keeper_path_rejection

let test_classifies_path_rejection_prefixes () =
  check bool "not found"
    true
    (CB.classify_error
       (R.rejection_to_user_message (R.Not_found_relative { raw = "repos/x" }))
     = CB.Path_not_found);
  check bool "outside sandbox"
    true
    (CB.classify_error
       (R.rejection_to_user_message (R.Outside_sandbox { raw = "repos/x" }))
     = CB.Path_not_allowed)
;;

let test_classifies_structured_error_text () =
  let payload =
    `Assoc
      [ ( "error"
        , `String
            (R.rejection_to_user_message (R.Outside_project_root { raw = "../x" })) )
      ]
    |> Yojson.Safe.to_string
  in
  check bool "structured path rejection"
    true
    (CB.classify_error ("tool_error: " ^ payload) = CB.Path_not_allowed)
;;

let test_classifies_shell_exit_fallback () =
  check bool "shell exit"
    true
    (CB.classify_error "process exited with code 2" = CB.Shell_exit_nonzero)
;;

let () =
  run
    "Keeper_failure_circuit_breaker_types"
    [ ( "classify"
      , [ test_case
            "path rejection prefixes"
            `Quick
            test_classifies_path_rejection_prefixes
        ; test_case "structured path rejection" `Quick test_classifies_structured_error_text
        ; test_case "shell exit fallback" `Quick test_classifies_shell_exit_fallback
        ] )
    ]
;;
