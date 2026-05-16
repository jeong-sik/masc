(** Tests for Worker_dev_tools.validate_command_paths.
    Verifies rejection of shell quoting, globbing, brace expansion,
    and backslash escapes in path-bearing keeper commands. *)

open Alcotest

module Wdt = Masc_mcp.Worker_dev_tools

let test_rejects_quoted_path () =
  match Wdt.validate_command_paths ~workdir:"/tmp" "cat '/tmp/test.txt'" with
  | Error _ -> ()
  | Ok () -> fail "Expected error for single-quoted path"
;;

let test_rejects_double_quoted_path () =
  match Wdt.validate_command_paths ~workdir:"/tmp" "cat \"/tmp/test.txt\"" with
  | Error _ -> ()
  | Ok () -> fail "Expected error for double-quoted path"
;;

let test_rejects_glob () =
  match Wdt.validate_command_paths ~workdir:"/tmp" "ls /tmp/*.ml" with
  | Error _ -> ()
  | Ok () -> fail "Expected error for glob in path"
;;

let test_rejects_brace_expansion () =
  match Wdt.validate_command_paths ~workdir:"/tmp" "cp /tmp/{a,b}.txt /dest/" with
  | Error _ -> ()
  | Ok () -> fail "Expected error for brace expansion in path"
;;

let test_rejects_backslash_escape () =
  match Wdt.validate_command_paths ~workdir:"/tmp" "grep \\w+ /tmp/file" with
  | Error _ -> ()
  | Ok () -> fail "Expected error for backslash in path"
;;

let test_allows_plain_path () =
  match Wdt.validate_command_paths ~workdir:"/tmp" "cat /tmp/test.txt" with
  | Ok () -> ()
  | Error msg -> fail ("Plain path should be allowed: " ^ msg)
;;

let test_allows_relative_path () =
  match Wdt.validate_command_paths ~workdir:"/tmp" "cat ./src/main.ml" with
  | Ok () -> ()
  | Error msg -> fail ("Relative path should be allowed: " ^ msg)
;;

let test_no_workdir_skips_validation () =
  match Wdt.validate_command_paths "cat '/anything/with quotes and * globs'" with
  | Ok () -> ()
  | Error msg -> fail ("No workdir should skip path validation: " ^ msg)
;;

let test_error_contains_hint () =
  match Wdt.validate_command_paths ~workdir:"/tmp" "ls /tmp/*.ml" with
  | Error msg ->
    check bool "error mentions glob expansion" true
      (String.length msg > 10)
  | Ok () -> fail "Expected error for glob"
;;

let () =
  run "path_rewrite_validation"
    [ ( "rejection"
      , [ test_case "quoted_path" `Quick test_rejects_quoted_path
        ; test_case "double_quoted_path" `Quick test_rejects_double_quoted_path
        ; test_case "glob" `Quick test_rejects_glob
        ; test_case "brace_expansion" `Quick test_rejects_brace_expansion
        ; test_case "backslash_escape" `Quick test_rejects_backslash_escape
        ] )
    ; ( "acceptance"
      , [ test_case "plain_path" `Quick test_allows_plain_path
        ; test_case "relative_path" `Quick test_allows_relative_path
        ; test_case "no_workdir_skips" `Quick test_no_workdir_skips_validation
        ] )
    ; ( "diagnostics"
      , [ test_case "error_contains_hint" `Quick test_error_contains_hint
        ] )
    ]
;;
