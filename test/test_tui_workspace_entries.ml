(* The Code pane's directory count: a full page is reported as truncated,
   because the server answers a bare list and the pane asked for its
   maximum. *)

open Masc_tui_types

let check_string = Alcotest.(check string)

let test_a_full_page_reads_as_more_not_listed () =
  let limit = workspace_entries_limit in
  check_string "the limit itself is the server maximum" "2000"
    (string_of_int Server_routes_http_routes_workspace.max_tree_node_limit);
  check_string "an empty directory has no count" "" (workspace_entries_count_label 0);
  check_string "a partial page is the total" " (955)" (workspace_entries_count_label 955);
  check_string "a full page says more may follow"
    (Printf.sprintf " (%d+, more not listed)" limit)
    (workspace_entries_count_label limit);
  check_string "past the limit still says so"
    (Printf.sprintf " (%d+, more not listed)" (limit + 1))
    (workspace_entries_count_label (limit + 1))
;;

let () =
  Alcotest.run
    "masc-tui-workspace-entries"
    [ ( "count label"
      , [ Alcotest.test_case "a full page reads as more not listed" `Quick
            test_a_full_page_reads_as_more_not_listed
        ] )
    ]
;;
