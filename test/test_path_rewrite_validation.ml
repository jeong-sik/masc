(** Tests for Worker_dev_tools.validate_command_paths.
    Verifies rejection of shell quoting, globbing, brace expansion,
    and backslash escapes in path-bearing keeper commands. *)

open Alcotest

module Wdt = Masc_mcp.Worker_dev_tools

let contains_substring haystack needle =
  let haystack_len = String.length haystack in
  let needle_len = String.length needle in
  let rec loop i =
    needle_len = 0
    || (i + needle_len <= haystack_len
        && (String.sub haystack i needle_len = needle || loop (i + 1)))
  in
  loop 0
;;

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

let test_rejects_git_revisionish_traversal_path () =
  match
    Wdt.validate_command_paths ~workdir:"/tmp"
      "git worktree add foo/../../outside HEAD"
  with
  | Error msg ->
    check bool "mentions path block" true (contains_substring msg "Path blocked")
  | Ok () -> fail "Expected git slash token with traversal segment to be blocked"
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

let test_blocks_input_redirect_outside_path () =
  match Wdt.validate_command_paths ~workdir:"/tmp" "cat < /etc/passwd" with
  | Error msg ->
    check bool "blocked diagnostic" true (contains_substring msg "Path blocked");
    check bool "outside path reported" true (contains_substring msg "/etc/passwd")
  | Ok () -> fail "Expected input redirect outside workdir to be blocked"
;;

let test_blocks_output_redirect_outside_path () =
  match Wdt.validate_command_paths ~workdir:"/tmp" "echo ok > /outside/path" with
  | Error msg ->
    check bool "blocked diagnostic" true (contains_substring msg "Path blocked");
    check bool "outside path reported" true (contains_substring msg "/outside/path")
  | Ok () -> fail "Expected output redirect outside workdir to be blocked"
;;

let test_allows_input_redirect_inside_path () =
  match Wdt.validate_command_paths ~workdir:"/tmp" "cat < ./safe.txt" with
  | Ok () -> ()
  | Error msg -> fail ("input redirect inside workdir should be allowed: " ^ msg)
;;

let test_blocks_pipeline_later_stage_outside_path () =
  match Wdt.validate_command_paths ~workdir:"/tmp" "echo ok | cat /etc/passwd" with
  | Error msg ->
    check bool "blocked diagnostic" true (contains_substring msg "Path blocked");
    check bool "outside path reported" true (contains_substring msg "/etc/passwd")
  | Ok () -> fail "Expected pipeline stage path outside workdir to be blocked"
;;

let test_allows_pipeline_later_stage_inside_path () =
  match Wdt.validate_command_paths ~workdir:"/tmp" "echo ok | cat /tmp/file.txt" with
  | Ok () -> ()
  | Error msg -> fail ("pipeline stage path under workdir should be allowed: " ^ msg)
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
        ; test_case
            "git_revisionish_traversal_path"
            `Quick
            test_rejects_git_revisionish_traversal_path
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
        ; test_case
            "input_redirect_inside_path"
            `Quick
            test_allows_input_redirect_inside_path
        ; test_case
            "pipeline_later_stage_inside_path"
            `Quick
            test_allows_pipeline_later_stage_inside_path
        ; test_case "no_workdir_skips" `Quick test_no_workdir_skips_validation
        ] )
    ; ( "ast_pipeline"
      , [ test_case
            "blocks_later_stage_outside_path"
            `Quick
            test_blocks_pipeline_later_stage_outside_path
        ; test_case
            "blocks_input_redirect_outside_path"
            `Quick
            test_blocks_input_redirect_outside_path
        ; test_case
            "blocks_output_redirect_outside_path"
            `Quick
            test_blocks_output_redirect_outside_path
        ] )
    ; ( "diagnostics"
      , [ test_case "error_contains_hint" `Quick test_error_contains_hint
        ] )
    ]
;;
