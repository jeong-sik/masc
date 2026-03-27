(** Base path resolution regression tests.

    Ensures explicit worktree paths stay isolated instead of collapsing
    to the repository root. *)

open Alcotest

let test_resolve_masc_base_path_preserves_explicit_path () =
  let worktree_path = "/tmp/masc-repo/.worktrees/feature-a" in
  let resolved = Room_utils.resolve_masc_base_path worktree_path in
  check string "explicit path preserved" worktree_path resolved

let test_default_config_preserves_explicit_worktree_path () =
  let base_path = "/tmp/masc-repo/.worktrees/feature-a" in
  let config = Room_utils.default_config base_path in
  check string "config base path preserved" base_path config.base_path;
  check string "workspace path preserved" base_path config.workspace_path;
  check string "backend base path scoped to worktree"
    (Filename.concat base_path ".masc")
    config.backend_config.base_path

let () =
  run "Base Path Resolution"
    [
      ( "base_path",
        [
          test_case "resolve keeps explicit worktree path" `Quick
            test_resolve_masc_base_path_preserves_explicit_path;
          test_case "default_config keeps explicit worktree path" `Quick
            test_default_config_preserves_explicit_worktree_path;
        ] );
    ]
