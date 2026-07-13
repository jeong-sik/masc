open Alcotest

module R = Keeper_path_rejection

let test_messages_are_direct_projections () =
  check string "path required" "path_required"
    (R.rejection_to_user_message R.Path_required);
  check string "invalid lexical endpoint"
    "invalid_lexical_endpoint: path must name a file entry other than '.' or '..'"
    (R.rejection_to_user_message R.Invalid_lexical_endpoint);
  check string "invalid allowed roots"
    "allowed_paths_normalized_empty: 2 entries provided, none resolved to a valid path"
    (R.rejection_to_user_message (R.Allowed_paths_normalized_empty { count = 2 }));
  check string "outside roots" "path_outside_sandbox: /tmp/x"
    (R.rejection_to_user_message (R.Outside_sandbox { raw = "/tmp/x" }))
;;

let () =
  run
    "Keeper_path_rejection"
    [ ( "projection"
      , [ test_case
            "typed rejections project directly"
            `Quick
            test_messages_are_direct_projections
        ] )
    ]
;;
