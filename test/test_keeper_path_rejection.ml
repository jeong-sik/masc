open Alcotest

module R = Keeper_path_rejection

let test_user_message_prefixes_are_classifiable () =
  let cases =
    [ R.Path_required
    ; R.Outside_project_root { raw = "../x" }
    ; R.Allowed_paths_normalized_empty { count = 2 }
    ; R.Outside_sandbox { raw = "repos/x" }
    ; R.Not_found_relative { raw = "repos/x/missing.ml" }
    ; R.Ambiguous_relative_read_path { raw = "lib/foo.ml"; candidate_count = 2 }
    ; R.Task_state_file_path_blocked { raw = ".masc/tasks/foo.json" }
    ]
  in
  List.iter
    (fun rejection ->
       check bool "message prefix classifies" true
         (Option.is_some
            (R.parse_rejection_prefix (R.rejection_to_user_message rejection))))
    cases
;;

let test_parse_is_case_insensitive_for_prefixes () =
  check bool "uppercase prefix"
    true
    (match R.parse_rejection_prefix "PATH_OUTSIDE_SANDBOX: repos/x" with
     | Some (R.Outside_sandbox _) -> true
     | _ -> false)
;;

let test_unknown_prefix_is_none () =
  check bool "unknown" true (Option.is_none (R.parse_rejection_prefix "not a path error"))
;;

let () =
  run
    "Keeper_path_rejection"
    [ ( "classification"
      , [ test_case
            "user messages are classifiable"
            `Quick
            test_user_message_prefixes_are_classifiable
        ; test_case "prefix matching is case-insensitive" `Quick
            test_parse_is_case_insensitive_for_prefixes
        ; test_case "unknown messages are ignored" `Quick test_unknown_prefix_is_none
        ] )
    ]
;;
