open Alcotest

let observed_path fields =
  Masc.Keeper_run_tools_hooks.observation_file_path_from_tool_input
    ~base_path:"/tmp/masc-base"
    (`Assoc fields)
;;

let test_explicit_cwd_scopes_relative_file_path () =
  check
    string
    "cwd/file_path"
    "repos/masc/lib/foo.ml"
    (observed_path
       [ "file_path", `String "lib/foo.ml"; "cwd", `String "repos/masc" ])
;;

let test_sandbox_rooted_file_path_ignores_cwd () =
  check
    string
    "sandbox-rooted"
    "repos/masc/lib/foo.ml"
    (observed_path
       [ "file_path", `String "repos/masc/lib/foo.ml"
       ; "cwd", `String "repos/other"
       ])
;;

let test_absolute_path_ignores_cwd () =
  check
    string
    "absolute"
    "/workspace/masc/lib/foo.ml"
    (observed_path
       [ "path", `String "/workspace/masc/lib/foo.ml"
       ; "cwd", `String "repos/other"
       ])
;;

let test_blank_path_falls_back_to_file_path () =
  check
    string
    "blank path fallback"
    "repos/masc/lib/foo.ml"
    (observed_path
       [ "path", `String " "
       ; "file_path", `String "repos/masc/lib/foo.ml"
       ])
;;

let test_missing_path_falls_back_to_base_path () =
  check string "base fallback" "/tmp/masc-base" (observed_path [])
;;

let () =
  run
    "keeper_run_tools_hooks"
    [ ( "observation_file_path"
      , [ test_case
            "explicit cwd scopes relative file_path"
            `Quick
            test_explicit_cwd_scopes_relative_file_path
        ; test_case
            "sandbox-rooted file_path ignores cwd"
            `Quick
            test_sandbox_rooted_file_path_ignores_cwd
        ; test_case "absolute path ignores cwd" `Quick test_absolute_path_ignores_cwd
        ; test_case "blank path falls back to file_path" `Quick
            test_blank_path_falls_back_to_file_path
        ; test_case "missing path falls back to base_path" `Quick
            test_missing_path_falls_back_to_base_path
        ] )
    ]
;;
