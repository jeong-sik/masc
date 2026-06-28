(** Regression test for [repo_root_public_prefix_from_cwd] and
    [repo_cwd_relative_rewrite] in [keeper_tool_execute_runtime.ml].

    PR-22578 extends prefix detection to worktree-shaped cwds
    ([repos/<repo>/.worktrees/<task>]). This test pins both the original
    behavior and the new worktree behavior so neither regresses silently.

    The helpers are exposed only through [For_testing] so the regression
    coverage does not become part of the public API. *)

open Alcotest
open Masc

let prefix_of cwd =
  Keeper_tool_execute_runtime.For_testing.repo_root_public_prefix_from_cwd cwd

let rewrite ~cwd path_argument =
  Keeper_tool_execute_runtime.For_testing.repo_cwd_relative_rewrite
    ~cwd
    path_argument

let test_root_prefix_at_repos_root () =
  check (option string)
    "abs path ending at repos/<repo> resolves"
    (Some "repos/foo/")
    (prefix_of "/home/keeper/.masc/playground/cheolsu/repos/foo")

let test_root_prefix_at_worktree_shape () =
  check (option string)
    "abs path with repos/<repo>/.worktrees/<task> resolves"
    (Some "repos/foo/")
    (prefix_of
       "/home/keeper/.masc/playground/cheolsu/repos/foo/.worktrees/PK-1")

let test_root_prefix_rejects_non_repos_cwd () =
  check (option string)
    "abs path without /repos/ in suffix returns None"
    None
    (prefix_of "/home/keeper/.masc/playground/cheolsu/mind")

let test_root_prefix_handles_relative_input () =
  check (option string)
    "relative path 'repos/<repo>' resolves"
    (Some "repos/foo/")
    (prefix_of "repos/foo")

let test_root_prefix_handles_relative_worktree () =
  check (option string)
    "relative path 'repos/<repo>/.worktrees/<task>' resolves"
    (Some "repos/foo/")
    (prefix_of "repos/foo/.worktrees/PK-1")

let test_rewrite_strips_repos_prefix () =
  let cwd = "/home/keeper/.masc/playground/cheolsu/repos/foo" in
  check (option string)
    "repos/<repo>/path/inside → path/inside"
    (Some "path/inside")
    (rewrite ~cwd "repos/foo/path/inside")

let test_rewrite_strips_repos_prefix_at_worktree () =
  let cwd =
    "/home/keeper/.masc/playground/cheolsu/repos/foo/.worktrees/PK-1"
  in
  check (option string)
    "worktree cwd + repos/<repo>/path/inside → path/inside"
    (Some "path/inside")
    (rewrite ~cwd "repos/foo/path/inside")

let test_rewrite_exact_repo_root_to_dot () =
  let cwd = "/home/keeper/.masc/playground/cheolsu/repos/foo" in
  check (option string)
    "exact repos/<repo> duplicate prefix rewrites to dot"
    (Some ".")
    (rewrite ~cwd "repos/foo");
  check (option string)
    "exact repos/<repo>/ duplicate prefix rewrites to dot"
    (Some ".")
    (rewrite ~cwd "repos/foo/")

let test_rewrite_rejects_parent_traversal_suffix () =
  let cwd = "/home/keeper/.masc/playground/cheolsu/repos/foo" in
  check (option string)
    "duplicate prefix rewrite does not suggest traversal"
    None
    (rewrite ~cwd "repos/foo/../bar")

let test_rewrite_noop_for_unrelated_path () =
  let cwd = "/home/keeper/.masc/playground/cheolsu/repos/foo" in
  check (option string)
    "path not starting with the prefix is not rewritten"
    None
    (rewrite ~cwd "mind/notes.md")

let test_rewrite_absolute_argument_returns_none () =
  let cwd = "/home/keeper/.masc/playground/cheolsu/repos/foo" in
  check (option string)
    "absolute path argument is not rewritten (cwd-relative contract only)"
    None
    (rewrite ~cwd "/etc/passwd")

let () =
  run "keeper_tool_execute_path_rewrite"
    [ "repo_root_public_prefix_from_cwd"
      , [ test_case
            "repos root resolves"
            `Quick
            test_root_prefix_at_repos_root
        ; test_case
            "worktree cwd resolves"
            `Quick
            test_root_prefix_at_worktree_shape
        ; test_case
            "non-repos cwd is ignored"
            `Quick
            test_root_prefix_rejects_non_repos_cwd
        ; test_case
            "relative repos cwd resolves"
            `Quick
            test_root_prefix_handles_relative_input
        ; test_case
            "relative worktree cwd resolves"
            `Quick
            test_root_prefix_handles_relative_worktree
        ]
    ; "repo_cwd_relative_rewrite"
      , [ test_case
            "strips duplicate repos prefix"
            `Quick
            test_rewrite_strips_repos_prefix
        ; test_case
            "strips duplicate repos prefix at worktree cwd"
            `Quick
            test_rewrite_strips_repos_prefix_at_worktree
        ; test_case
            "exact duplicate repo root rewrites to dot"
            `Quick
            test_rewrite_exact_repo_root_to_dot
        ; test_case
            "duplicate prefix traversal is not rewritten"
            `Quick
            test_rewrite_rejects_parent_traversal_suffix
        ; test_case
            "unrelated path is unchanged"
            `Quick
            test_rewrite_noop_for_unrelated_path
        ; test_case
            "absolute path is unchanged"
            `Quick
            test_rewrite_absolute_argument_returns_none
        ]
    ]
