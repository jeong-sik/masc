(** Regression test for [repo_root_public_prefix_from_cwd] and
    [repo_cwd_relative_rewrite] in [keeper_tool_execute_runtime.ml].

    PR-22578 (path-helper SSOT) lifts the [string_has_prefix] hand-roll to
    stdlib [String.starts_with] and extends the prefix detection to
    worktree-shaped cwds ([repos/<repo>/.worktrees/<task>]). This test
    pins both the original behavior and the new worktree behavior so
    neither regresses silently.

    The helpers are exposed only through [For_testing] so the regression
    coverage does not become part of the public API. *)

open Alcotest

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

let test_uses_stdlib_string_starts_with () =
  (* Source-level pin: the helper must call stdlib [String.starts_with],
     not the hand-rolled [string_has_prefix] (PR-22578 P1 SSOT). The
     helper is a small function whose replacement was the entire point of
     the PR, so a sentinel substring on the source file is a cheap,
     compiler-checked contract. *)
  let path = "lib/keeper/keeper_tool_execute_runtime.ml" in
  let find_in_path () =
    let candidates =
      [ path
      ; "../" ^ path
      ; "../../" ^ path
      ]
    in
    List.find_opt Sys.file_exists candidates
  in
  match find_in_path () with
  | None -> ()
  | Some resolved ->
    let src =
      let ic = open_in resolved in
      Fun.protect
        ~finally:(fun () -> close_in_noerr ic)
        (fun () ->
          let buf = Buffer.create 16384 in
          (try
             while true do
               Buffer.add_string buf (input_line ic);
               Buffer.add_char buf '\n'
             done
           with End_of_file -> ());
          Buffer.contents buf)
    in
    check bool
      "keeper_tool_execute_runtime.ml does NOT define hand-rolled string_has_prefix"
      false
      (Astring.String.is_infix
         ~affix:"let string_has_prefix ~prefix"
         src);
    check bool
      "keeper_tool_execute_runtime.ml uses stdlib String.starts_with"
      true
      (Astring.String.is_infix
         ~affix:"String.starts_with ~prefix"
         src)

let () =
  run "keeper_tool_execute_path_rewrite"
    [ "repo_root_public_prefix_from_cwd"
      , [ test_root_prefix_at_repos_root ()
        ; test_root_prefix_at_worktree_shape ()
        ; test_root_prefix_rejects_non_repos_cwd ()
        ; test_root_prefix_handles_relative_input ()
        ; test_root_prefix_handles_relative_worktree ()
        ]
    ; "repo_cwd_relative_rewrite"
      , [ test_rewrite_strips_repos_prefix ()
        ; test_rewrite_strips_repos_prefix_at_worktree ()
        ; test_rewrite_noop_for_unrelated_path ()
        ; test_rewrite_absolute_argument_returns_none ()
        ]
    ; "ssot_pins"
      , [ test_uses_stdlib_string_starts_with () ]
    ]
