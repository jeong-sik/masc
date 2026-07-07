open Alcotest

module CB = Keeper_failure_circuit_breaker_types
module P = Keeper_path_check_error
module R = Keeper_path_rejection

let error_class =
  testable
    (fun fmt cls -> Format.pp_print_string fmt (CB.error_class_to_string cls))
    ( = )
;;

let check_class label expected actual = check error_class label expected actual

let check_optional_class label expected actual =
  check (option error_class) label (Some expected) actual
;;

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

let test_classifies_typed_path_check_errors () =
  let cwd_not_directory =
    P.Cwd_not_directory { path = "repos/missing"; hint = Some "create it first" }
  in
  let path_outside_whitelist =
    P.Path_outside_whitelist
      { path = "/etc/passwd"; for_keeper_command = false }
  in
  check_class "typed cwd" CB.Cwd_not_directory
    (CB.classify_typed_path_check cwd_not_directory);
  check_optional_class "prefix cwd" CB.Cwd_not_directory
    (CB.classify_path_check_prefix (P.to_message cwd_not_directory));
  check_class "typed outside whitelist" CB.Path_not_allowed
    (CB.classify_typed_path_check path_outside_whitelist);
  check_optional_class "prefix outside whitelist" CB.Path_not_allowed
    (CB.classify_path_check_prefix (P.to_message path_outside_whitelist))
;;

let test_classifies_typed_path_rejections () =
  let cases =
    [ ( "path required", R.Path_required, CB.Other )
    ; ( "absolute path"
      , R.Absolute_path_rejected { raw = "/tmp/x" }
      , CB.Path_not_allowed )
    ; ( "outside project"
      , R.Outside_project_root { raw = "../x" }
      , CB.Path_not_allowed )
    ; ( "empty allowed paths"
      , R.Allowed_paths_normalized_empty { count = 2 }
      , CB.Other )
    ; "outside sandbox", R.Outside_sandbox { raw = "repos/x" }, CB.Path_not_allowed
    ; "not found", R.Not_found_relative { raw = "repos/x" }, CB.Path_not_found
    ; ( "ambiguous relative"
      , R.Ambiguous_relative_read_path { raw = "foo.ml"; candidate_count = 2 }
      , CB.Other )
    ; ( "task state blocked"
      , R.Task_state_file_path_blocked { raw = ".masc/tasks.json" }
      , CB.Path_not_allowed )
    ]
  in
  List.iter
    (fun (label, rejection, expected) ->
       check_class (label ^ "/typed") expected
         (CB.classify_typed_path_rejection rejection);
       check_optional_class (label ^ "/prefix") expected
         (CB.classify_path_rejection_prefix
            (R.rejection_to_user_message rejection)))
    cases
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
        ; test_case
            "typed path check errors"
            `Quick
            test_classifies_typed_path_check_errors
        ; test_case
            "typed path rejections"
            `Quick
            test_classifies_typed_path_rejections
        ] )
    ]
;;
