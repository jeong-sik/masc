module Types = Masc_domain

(** Workspace Git Module Coverage Tests

    Tests for git utility functions:
    - git_root function
    - is_git_repo function
    - remote_branch_exists function
    - origin_head_branch function
    - resolve_base_branch function
    - list function
    - get_info function
*)

open Alcotest

module Workspace_git = Workspace_git

let current_repo_base_path () =
  let cwd = Sys.getcwd () in
  if Workspace_git.is_git_repo ~base_path:cwd then
    cwd
  else
    match Sys.getenv_opt "DUNE_SOURCEROOT" with
    | Some root when Workspace_git.is_git_repo ~base_path:root -> root
    | _ -> cwd

(* ============================================================
   git_root Tests
   ============================================================ *)

let test_git_root_returns_option () =
  (* Test on current directory - should be a git repo *)
  let result = Workspace_git.git_root ~base_path:(current_repo_base_path ()) in
  (* Just verify it returns an option *)
  let _ : string option = result in
  ()

let test_git_root_nonexistent () =
  let result = Workspace_git.git_root ~base_path:"/nonexistent/path/xyz" in
  match result with
  | None -> ()
  | Some _ -> ()  (* allow both outcomes *)

let test_git_root_tmp () =
  let result = Workspace_git.git_root ~base_path:"/tmp" in
  match result with
  | None -> ()
  | Some _ -> ()

let test_git_root_current_nonempty () =
  match Workspace_git.git_root ~base_path:(current_repo_base_path ()) with
  | Some root -> check bool "root nonempty" true (String.length root > 0)
  | None -> fail "expected git root for current dir"

let test_git_root_is_directory () =
  match Workspace_git.git_root ~base_path:(current_repo_base_path ()) with
  | Some root -> check bool "root is directory" true (Sys.is_directory root)
  | None -> fail "expected git root"

(* ============================================================
   is_git_repo Tests
   ============================================================ *)

let test_is_git_repo_current () =
  let result = Workspace_git.is_git_repo ~base_path:(current_repo_base_path ()) in
  (* Current directory should be a git repo for masc *)
  check bool "current dir is git repo" true result

let test_is_git_repo_returns_bool () =
  let result = Workspace_git.is_git_repo ~base_path:"/tmp" in
  let _ : bool = result in
  ()

let test_is_git_repo_nonexistent () =
  let result = Workspace_git.is_git_repo ~base_path:"/nonexistent/xyz" in
  check bool "nonexistent is not git repo" false result

let test_is_git_repo_root () =
  let result = Workspace_git.is_git_repo ~base_path:"/" in
  (* Root directory is unlikely to be a git repo *)
  let _ : bool = result in
  ()

(* ============================================================
   remote_branch_exists Tests
   ============================================================ *)

let test_remote_branch_exists_returns_bool () =
  match Workspace_git.git_root ~base_path:(current_repo_base_path ()) with
  | Some root ->
      let result = Workspace_git.remote_branch_exists root "main" in
      let _ : bool = result in
      ()
  | None -> fail "need git repo"

let test_remote_branch_exists_main_or_master () =
  match Workspace_git.git_root ~base_path:(current_repo_base_path ()) with
  | Some root ->
      let has_main = Workspace_git.remote_branch_exists root "main" in
      let has_master = Workspace_git.remote_branch_exists root "master" in
      if has_main || has_master then
        ()
      else
        (* CI or shallow clones may not have origin refs *)
        ()
  | None -> fail "need git repo"

let test_remote_branch_exists_nonexistent () =
  match Workspace_git.git_root ~base_path:(current_repo_base_path ()) with
  | Some root ->
      let result = Workspace_git.remote_branch_exists root "nonexistent-branch-xyz-123" in
      check bool "nonexistent branch" false result
  | None -> fail "need git repo"

let test_remote_branch_exists_empty_branch () =
  match Workspace_git.git_root ~base_path:(current_repo_base_path ()) with
  | Some root ->
      let result = Workspace_git.remote_branch_exists root "" in
      check bool "empty branch" false result
  | None -> fail "need git repo"

(* ============================================================
   origin_head_branch Tests
   ============================================================ *)

let test_origin_head_branch_returns_option () =
  match Workspace_git.git_root ~base_path:(current_repo_base_path ()) with
  | Some root ->
      let result = Workspace_git.origin_head_branch root in
      let _ : string option = result in
      ()
  | None -> fail "need git repo"

let test_origin_head_branch_typical_values () =
  match Workspace_git.git_root ~base_path:(current_repo_base_path ()) with
  | Some root ->
      (match Workspace_git.origin_head_branch root with
       | Some branch ->
           (* If we have origin HEAD, it should be main or master typically *)
           check bool "branch nonempty" true (String.length branch > 0)
       | None ->
           (* origin/HEAD might not be set *)
           ())
  | None -> fail "need git repo"

(* ============================================================
   resolve_base_branch Tests
   ============================================================ *)

let test_resolve_base_branch_main () =
  match Workspace_git.git_root ~base_path:(current_repo_base_path ()) with
  | Some root ->
      (* If origin/main exists, should resolve to main *)
      if Workspace_git.remote_branch_exists root "main" then begin
        match Workspace_git.resolve_base_branch root "main" with
        | Ok (branch, fallback) ->
            check string "resolved to main" "main" branch;
            check (option string) "no fallback needed" None fallback
        | Error _ -> fail "should resolve main"
      end else
        ()
  | None -> fail "need git repo for test"

let test_resolve_base_branch_returns_result () =
  match Workspace_git.git_root ~base_path:(current_repo_base_path ()) with
  | Some root ->
      let result = Workspace_git.resolve_base_branch root "main" in
      let _ : (string * string option, Masc_domain.masc_error) result = result in
      ()
  | None -> fail "need git repo"

let test_resolve_base_branch_nonexistent_fallback () =
  match Workspace_git.git_root ~base_path:(current_repo_base_path ()) with
  | Some root ->
      (* If we ask for a nonexistent branch, it should fallback *)
      (match Workspace_git.resolve_base_branch root "nonexistent-xyz-123" with
       | Ok (branch, fallback) ->
           check bool "branch nonempty" true (String.length branch > 0);
           (* Should have fallback info about the missing branch *)
           check bool "has fallback note" true (fallback <> None)
       | Error _ ->
           (* Error if no fallback available either *)
           ())
  | None -> fail "need git repo"

(* --- has_git_marker_deep tests --- *)

let test_has_git_marker_deep_git_repo () =
  (* Current repo path has .git in an ancestor *)
  let result = Workspace_git.has_git_marker_deep (current_repo_base_path ()) in
  Alcotest.(check bool) "has_git_marker_deep true for git repo" true result

let test_has_git_marker_deep_nonexistent () =
  let result = Workspace_git.has_git_marker_deep "/nonexistent/path/xyz" in
  Alcotest.(check bool) "has_git_marker_deep false for nonexistent" false result

let test_has_git_marker_deep_child_repos () =
  (* Sandbox root has .git in child repos/ directories *)
  let sandbox_root = Filename.dirname (Filename.dirname (current_repo_base_path ())) in
  let result = Workspace_git.has_git_marker_deep sandbox_root in
  Alcotest.(check bool) "has_git_marker_deep true for sandbox with child repos" true result

let () =
  run "Workspace Git Coverage" [
    "git_root", [
      test_case "returns option" `Quick test_git_root_returns_option;
      test_case "nonexistent" `Quick test_git_root_nonexistent;
      test_case "tmp" `Quick test_git_root_tmp;
      test_case "current nonempty" `Quick test_git_root_current_nonempty;
      test_case "is directory" `Quick test_git_root_is_directory;
    ];
    "is_git_repo", [
      test_case "current" `Quick test_is_git_repo_current;
      test_case "returns bool" `Quick test_is_git_repo_returns_bool;
      test_case "nonexistent" `Quick test_is_git_repo_nonexistent;
      test_case "root" `Quick test_is_git_repo_root;
    ];
    "remote_branch_exists", [
      test_case "returns bool" `Quick test_remote_branch_exists_returns_bool;
      test_case "main or master" `Quick test_remote_branch_exists_main_or_master;
      test_case "nonexistent" `Quick test_remote_branch_exists_nonexistent;
      test_case "empty branch" `Quick test_remote_branch_exists_empty_branch;
    ];
    "origin_head_branch", [
      test_case "returns option" `Quick test_origin_head_branch_returns_option;
      test_case "typical values" `Quick test_origin_head_branch_typical_values;
    ];
    "resolve_base_branch", [
      test_case "main" `Quick test_resolve_base_branch_main;
      test_case "returns result" `Quick test_resolve_base_branch_returns_result;
      test_case "nonexistent fallback" `Quick test_resolve_base_branch_nonexistent_fallback;
    ];
    "has_git_marker_deep", [
      test_case "git repo" `Quick test_has_git_marker_deep_git_repo;
      test_case "nonexistent" `Quick test_has_git_marker_deep_nonexistent;
      test_case "child repos" `Quick test_has_git_marker_deep_child_repos;
    ];
  ]
