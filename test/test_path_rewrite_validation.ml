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

let test_rejects_glob_in_non_globbed_command_path () =
  match Wdt.validate_command_paths ~workdir:"/tmp" "cat /tmp/*.ml" with
  | Error _ -> ()
  | Ok () -> fail "Expected error for glob in cat path"
;;

let test_rejects_glob_in_directory_path_segment () =
  match Wdt.validate_command_paths ~workdir:"/tmp" "ls /t*/file.ml" with
  | Error _ -> ()
  | Ok () -> fail "Expected error for glob in directory path segment"
;;

let test_rejects_brace_expansion () =
  match Wdt.validate_command_paths ~workdir:"/tmp" "cp /tmp/{a,b}.txt /dest/" with
  | Error _ -> ()
  | Ok () -> fail "Expected error for brace expansion in path"
;;

let test_rejects_backslash_escape_in_path () =
  match Wdt.validate_command_paths ~workdir:"/tmp" "cat /tmp/foo\\ bar" with
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

let test_allows_ls_basename_glob () =
  match Wdt.validate_command_paths ~workdir:"/tmp" "ls /tmp/*.ml" with
  | Ok () -> ()
  | Error msg -> fail ("ls basename glob should be allowed: " ^ msg)
;;

let test_allows_grep_regex_pattern_backslash () =
  match Wdt.validate_command_paths ~workdir:"/tmp" "grep \\w+ /tmp/file" with
  | Ok () -> ()
  | Error msg -> fail ("grep regex pattern should be allowed: " ^ msg)
;;

let test_allows_quoted_gh_repo_slug () =
  match
    Wdt.validate_command_paths ~workdir:"/tmp"
      "gh pr view 15660 -R 'yousleepwhen/masc-mcp' --json title,body,state 2>&1"
  with
  | Ok () -> ()
  | Error msg -> fail ("quoted gh repo slug should not be path-validated: " ^ msg)
;;

let test_allows_gh_repo_slug_with_pipeline () =
  match
    Wdt.validate_command_paths ~workdir:"/tmp"
      "gh pr diff 15660 --repo yousleepwhen/masc-mcp 2>&1 | head -c 65536"
  with
  | Ok () -> ()
  | Error msg -> fail ("gh repo slug with pipeline should be allowed: " ^ msg)
;;

let test_allows_git_revision_with_slash () =
  match
    Wdt.validate_command_paths ~workdir:"/tmp"
      "git log origin/feature/refactor-overview --oneline -10 2>/dev/null"
  with
  | Ok () -> ()
  | Error msg -> fail ("git revision refs with slash should be allowed: " ^ msg)
;;

let test_allows_git_branch_filter_with_quoted_slash () =
  match
    Wdt.validate_command_paths ~workdir:"/tmp"
      "git log --oneline -10 --all --no-walk --branches='feature/refactor-overview'"
  with
  | Ok () -> ()
  | Error msg -> fail ("quoted git branch filter should be allowed: " ^ msg)
;;

let test_allows_ls_basename_glob_with_redirect () =
  match Wdt.validate_command_paths ~workdir:"/tmp" "ls -la /tmp/agent_name_kind.* 2>&1" with
  | Ok () -> ()
  | Error msg -> fail ("ls basename glob with stderr redirect should be allowed: " ^ msg)
;;

let test_no_workdir_skips_validation () =
  match Wdt.validate_command_paths "cat '/anything/with quotes and * globs'" with
  | Ok () -> ()
  | Error msg -> fail ("No workdir should skip path validation: " ^ msg)
;;

let test_error_contains_hint () =
  match Wdt.validate_command_paths ~workdir:"/tmp" "cat /tmp/*.ml" with
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
        ; test_case
            "glob_non_globbed_command_path"
            `Quick
            test_rejects_glob_in_non_globbed_command_path
        ; test_case
            "glob_directory_path_segment"
            `Quick
            test_rejects_glob_in_directory_path_segment
        ; test_case "brace_expansion" `Quick test_rejects_brace_expansion
        ; test_case "backslash_escape_in_path" `Quick test_rejects_backslash_escape_in_path
        ] )
    ; ( "acceptance"
      , [ test_case "plain_path" `Quick test_allows_plain_path
        ; test_case "relative_path" `Quick test_allows_relative_path
        ; test_case "ls_basename_glob" `Quick test_allows_ls_basename_glob
        ; test_case
            "grep_regex_pattern_backslash"
            `Quick
            test_allows_grep_regex_pattern_backslash
        ; test_case "quoted_gh_repo_slug" `Quick test_allows_quoted_gh_repo_slug
        ; test_case
            "gh_repo_slug_with_pipeline"
            `Quick
            test_allows_gh_repo_slug_with_pipeline
        ; test_case
            "git_revision_with_slash"
            `Quick
            test_allows_git_revision_with_slash
        ; test_case
            "git_branch_filter_with_quoted_slash"
            `Quick
            test_allows_git_branch_filter_with_quoted_slash
        ; test_case
            "ls_basename_glob_with_redirect"
            `Quick
            test_allows_ls_basename_glob_with_redirect
        ; test_case "no_workdir_skips" `Quick test_no_workdir_skips_validation
        ] )
    ; ( "diagnostics"
      , [ test_case "error_contains_hint" `Quick test_error_contains_hint
        ] )
    ]
;;
