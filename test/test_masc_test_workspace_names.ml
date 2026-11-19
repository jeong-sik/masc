(** [Masc_test_deps.setup_test_workspace]: a workspace's name is one no
    earlier workspace of the process had.

    A test removes its workspace when it ends, and the next test of the same
    executable makes one right after. What the process remembers by path is
    not removed with the directory: [Fs_compat.mkdir_p_memoized] still holds
    that the store's month directory was made. Under the same name the next
    test's first append skips making that directory and fails with "No such
    file or directory". *)

open Alcotest

let workspaces = 200

let test_a_name_is_not_used_twice () =
  let names =
    List.init workspaces (fun _ ->
      let workspace = Masc_test_deps.setup_test_workspace () in
      Masc_test_deps.cleanup_test_workspace workspace;
      workspace)
  in
  check
    int
    "each workspace had its own name"
    workspaces
    (List.length (List.sort_uniq String.compare names))
;;

let () =
  run
    "masc_test_workspace_names"
    [ ( "the shared test workspace"
      , [ test_case "a name is not used twice" `Quick test_a_name_is_not_used_twice ] )
    ]
;;
