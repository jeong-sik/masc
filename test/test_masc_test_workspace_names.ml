(** [Masc_test_deps.setup_test_workspace]: a workspace's name is one no
    earlier workspace of the process had.

    A test removes its workspace when it ends, and the next test of the same
    executable makes one right after. What the process keeps under the
    directory's name is not removed with the directory: the facts a store
    keeps beside its files ([Dated_jsonl.read_fact]) stay. Under the same
    name the next test would be answered with the earlier workspace's rows. *)

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
