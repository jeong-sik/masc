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

module Decode = Masc.Tui_decode
module Fetched = Masc_tui_fetched

let start_read ~equal fetched key =
  match Fetched.start ~equal fetched ~key with
  | Fetched.Started (next, request) -> next, request
  | Fetched.Already_loading -> Alcotest.fail "fixture already loading"

let activity_change index : Decode.file_change =
  { fc_at = float_of_int index
  ; fc_keeper = "alpha"
  ; fc_turn = Some index
  ; fc_task_id = Some "task-1"
  ; fc_execution_id = None
  ; fc_line_evidence = None
  ; fc_location = Decode.Fc_in_repo
      { repo_id = "masc"; relative_path = Printf.sprintf "lib/file-%d.ml" index }
  ; fc_kind = Decode.Fc_written { content = "let value = 1" }
  ; fc_succeeded = true
  }

let activity_read changes =
  { war_at = 0.; war_hours = 24.
  ; war_keepers =
      [ "alpha", Ok
          { Decode.fcs_keeper = "alpha"; fcs_window_hours = 24.
          ; fcs_calls_in_window = List.length changes; fcs_changes = changes
          ; fcs_over_budget = 0; fcs_malformed = 0
          }
      ]
  }

let refresh_activity state changes =
  let next, request = start_read ~equal:String.equal state.workspace_activity "masc" in
  state.workspace_activity <- next;
  apply_workspace_activity_read state request (Ok (activity_read changes))

let test_activity_refresh_reconciles_visible_selection () =
  let state = create_state ~workspace:"" ~port:0 ~refresh_interval:0. () in
  state.workspace_activity_repo <- Some "masc";
  refresh_activity state (List.init 20 activity_change);
  state.workspace_activity_cursor <- 19;
  refresh_activity state [activity_change 42];
  let rows, cursor, selected = workspace_activity_selection state in
  Alcotest.(check int) "one refreshed row" 1 (List.length rows);
  Alcotest.(check int) "stored cursor reconciles on response" 0 state.workspace_activity_cursor;
  Alcotest.(check int) "render cursor" 0 cursor;
  Alcotest.(check (option string)) "Enter opens the row the frame selects"
    (Some "lib/file-42.ml") (Option.map snd selected);
  (* Even before a response reconciles state, Enter has the renderer's clamp. *)
  state.workspace_activity_cursor <- 19;
  let _, _, selected = workspace_activity_selection state in
  Alcotest.(check (option string)) "out-of-range input shares the visible row"
    (Some "lib/file-42.ml") (Option.map snd selected);
  refresh_activity state [];
  let _, cursor, selected = workspace_activity_selection state in
  Alcotest.(check int) "empty reading resets cursor" 0 cursor;
  Alcotest.(check bool) "empty reading has no file to open" true (Option.is_none selected)

let test_activity_file_starts_without_old_overlays () =
  let state = create_state ~workspace:"" ~port:0 ~refresh_interval:0. () in
  state.view <- Repositories;
  state.code_history_open <- true;
  state.code_diff_open <- true;
  state.code_notes_open <- true;
  state.code_lsp_note <- Some "old hover";
  state.code_target_line <- Some 200;
  state.code_file_scroll <- 199;
  let history, old_history =
    start_read ~equal:( = ) state.code_history (Code_scope_keeper "beta", "old.ml")
  in
  state.code_history <- history;
  let diff, old_diff = start_read ~equal:String.equal state.code_diff "old.ml" in
  state.code_diff <- diff;
  let blame, old_blame = start_read ~equal:String.equal state.code_blame "old.ml" in
  state.code_blame <- blame;
  enter_keeper_code_file state ~keeper:"alpha" ~path:"repos/masc/lib/new.ml";
  check_string "file's containing directory" "repos/masc/lib" state.code_dir;
  Alcotest.(check bool) "reads the writing Keeper's bundle" true
    (state.code_scope = Code_scope_keeper "alpha");
  Alcotest.(check bool) "opens file pane" true
    (state.view = Code && state.code_focus_file = Right_pane);
  Alcotest.(check bool) "closes all sibling overlays before the request" false
    (state.code_history_open || state.code_diff_open || state.code_notes_open);
  Alcotest.(check bool) "clears old hover and line target" true
    (state.code_lsp_note = None && state.code_target_line = None);
  Alcotest.(check int) "new content starts at top" 0 state.code_file_scroll;
  (* The new read may fail; late answers for the old file still cannot revive
     its overlays or blame next to the failure. *)
  let file, request = start_read ~equal:String.equal state.code_file "repos/masc/lib/new.ml" in
  state.code_file <- Fetched.complete ~equal:String.equal file request (Error "unreadable");
  state.code_history <- Fetched.complete ~equal:( = ) state.code_history old_history
    (Ok {chl_entries = []; chl_activity_note = "old file"});
  state.code_diff <- Fetched.complete ~equal:String.equal state.code_diff old_diff (Error "old diff");
  state.code_blame <- Fetched.complete ~equal:String.equal state.code_blame old_blame (Ok []);
  Alcotest.(check bool) "late history discarded" true (Option.is_none (Fetched.current state.code_history));
  Alcotest.(check bool) "late diff discarded" true (Option.is_none (Fetched.current state.code_diff));
  Alcotest.(check bool) "late blame discarded" true (Option.is_none (Fetched.current state.code_blame));
  Alcotest.(check bool) "returns to activity" true
    (state.followed_from = Some (Repositories, None))

let () =
  Alcotest.run
    "masc-tui-workspace-entries"
    [ ( "count label"
      , [ Alcotest.test_case "a full page reads as more not listed" `Quick
            test_a_full_page_reads_as_more_not_listed
        ] )
    ; ( "activity"
      , [ Alcotest.test_case "refresh preserves the visible Enter target" `Quick
            test_activity_refresh_reconciles_visible_selection
        ; Alcotest.test_case "failed file cannot retain old overlays" `Quick
            test_activity_file_starts_without_old_overlays
        ] )
    ]
;;
