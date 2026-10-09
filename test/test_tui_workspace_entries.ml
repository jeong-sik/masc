(* The Code pane's directory count: a full page is reported as truncated,
   because the server answers a bare list and the pane asked for its
   maximum. *)

open Masc_tui_types

let check_string = Alcotest.(check string)

module Decode = Masc.Tui_decode
module Fetched = Masc_tui_fetched
module Code_results = Masc_tui_code_results

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

let activity_read changes : workspace_activity_read =
  { ras_repo_id = "masc"; ras_window_hours = 24.; ras_changes = changes;
    ras_incomplete = 0; ras_unattributed = 0 }

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
  state.code_file <- file;
  Code_results.apply_file state request (Error "unreadable");
  Code_results.apply_history state old_history
    (Ok {chl_entries = []; chl_git_error = None; chl_activity_note = "old file"});
  Code_results.apply_diff state old_diff (Error "old diff");
  Code_results.apply_blame state old_blame (Ok []);
  Alcotest.(check bool) "late history discarded" true (Option.is_none (Fetched.current state.code_history));
  Alcotest.(check bool) "late diff discarded" true (Option.is_none (Fetched.current state.code_diff));
  Alcotest.(check bool) "late blame discarded" true (Option.is_none (Fetched.current state.code_blame));
  Alcotest.(check bool) "returns to activity" true
    (state.followed_from = Some (Repositories, None))

(* The Code pane fetches a directory listing per scope, and until #33946 the
   reply named only the directory. Two scopes can hold the same relative
   directory -- "lib" under one keeper's bundle and under another's -- so a
   reply that arrived after the operator switched scope was accepted as the
   new scope's rows.

   The listing now travels under the same key its history already used. What
   the key has to answer is this: a shared path is not a shared request. *)
let test_a_shared_path_is_not_a_shared_request () =
  let check name expected left right =
    Alcotest.(check bool) name expected (code_scope_path_equal left right)
  in
  check "the same path under two keepers is two requests" false
    (Code_scope_keeper "alpha", "lib") (Code_scope_keeper "beta", "lib");
  check "a keeper's bundle is not the project tree" false
    (Code_scope_keeper "alpha", "lib") (Code_scope_project, "lib");
  check "a repository is not a keeper of the same name" false
    (Code_scope_repo "masc", "lib") (Code_scope_keeper "masc", "lib");
  check "two directories under one scope are two requests" false
    (Code_scope_project, "lib") (Code_scope_project, "bin");
  check "both halves agreeing is the same request" true
    (Code_scope_keeper "alpha", "lib") (Code_scope_keeper "alpha", "lib");
  check "the project root agrees with itself" true
    (Code_scope_project, "") (Code_scope_project, "")
;;

(* The key is what [Masc_tui_fetched] discriminates on, so the pane that
   already uses it must drop a reply from the scope just left. Driven through
   the module rather than asserted about the equality alone: the equality
   being right says nothing about the pane consulting it. *)
let test_a_reply_from_the_scope_just_left_is_dropped () =
  let equal = code_scope_path_equal in
  let state = create_state ~workspace:"" ~port:0 ~refresh_interval:0. () in
  let pending, from_alpha =
    start_read ~equal state.code_history (Code_scope_keeper "alpha", "lib/x.ml")
  in
  state.code_history <- pending;
  let switched, _ =
    start_read ~equal pending (Code_scope_keeper "beta", "lib/x.ml")
  in
  state.code_history <- switched;
  Code_results.apply_history state from_alpha
      (Ok { chl_entries = []; chl_git_error = None; chl_activity_note = "alpha" });
  Alcotest.(check bool) "the pane is still waiting on beta" true
    (match Fetched.current state.code_history with
     | Some ((Code_scope_keeper "beta", "lib/x.ml"), Fetched.Loading) -> true
     | Some _ | None -> false)
;;

(* The listing is keyed the same way. It was three cells -- rows, an error,
   and one in-flight bit shared by every directory -- so moving into a
   directory before the last listing answered asked for nothing, and the late
   answer for the directory just left was dropped without the new one ever
   being requested: "(loading…)" until [r]. The same cells drew a directory
   that answered with no entries as "(loading…)" too. *)
let test_moving_before_the_listing_answers_asks_for_the_new_directory () =
  let equal = code_scope_path_equal in
  let state = create_state ~workspace:"" ~port:0 ~refresh_interval:0. () in
  let view_is name expected =
    Alcotest.(check string) name expected
      (match code_listing_view state with
       | Fetched.Absent -> "absent"
       | Fetched.Loading -> "loading"
       | Fetched.Ready [] -> "empty"
       | Fetched.Ready (_ :: _) -> "rows"
       | Fetched.Stale _ -> "stale"
       | Fetched.Failed _ -> "failed")
  in
  view_is "a listing nobody asked for is absent" "absent";
  let listing, from_root =
    start_read ~equal state.code_listing (Code_scope_project, "")
  in
  state.code_listing <- listing;
  state.code_dir <- "lib";
  let listing, from_lib =
    start_read ~equal state.code_listing (Code_scope_project, "lib")
  in
  state.code_listing <- listing;
  view_is "lib is asked for while the root is still in flight" "loading";
  Code_results.apply_entries state from_root (Ok []);
  view_is "the root's late answer does not settle lib" "loading";
  Code_results.apply_entries state from_lib (Ok []);
  view_is "a directory with no entries is an answer, not a wait" "empty";
  Alcotest.(check int) "and it holds no rows" 0 (List.length (code_entries state))
;;

let test_file_reply_and_lsp_navigation_share_current_content () =
  let state = create_state ~workspace:"" ~port:0 ~refresh_interval:0. () in
  let old, old_request = start_read ~equal:String.equal state.code_file "old.ml" in
  let current, request = start_read ~equal:String.equal old "new.ml" in
  state.code_file <- current;
  Code_results.apply_file state request (Ok "let first = 1\nlet second = 2");
  state.code_file_cursor <- 1;
  let shown = state.code_file in
  Code_results.apply_file state old_request (Ok "old bytes");
  Alcotest.(check bool) "late file does not replace current content" true
    (state.code_file = shown);
  Alcotest.(check int) "late file does not reset the selected line" 1 state.code_file_cursor;
  let location path inside line : Decode.lsp_location =
    {ll_path = path; ll_inside = inside; ll_line = line}
  in
  let answer location =
    let request = match Code_results.start_lsp_question state ~question:"definition" ~symbol:"first" with
      | Some request -> request | None -> Alcotest.fail "question did not start" in
    Code_results.apply_lsp_answer state request (Ok (Decode.Lsp_locations [location]))
  in
  Alcotest.(check bool) "same-file definition requests reveal, not another load" true
    (answer (location "new.ml" true 1) = Code_results.Reveal_cursor);
  Alcotest.(check int) "definition selects its line" 0 state.code_file_cursor;
  let jumps = List.length state.code_jump_back in
  Alcotest.(check bool) "outside definition stays on current content" true
    (answer (location "stdlib.ml" false 4) = Code_results.No_followup);
  Alcotest.(check int) "outside definition does not add a back entry" jumps
    (List.length state.code_jump_back);
  Alcotest.(check bool) "different file requests its own load" true
    (answer (location "other.ml" true 7) = Code_results.Load_file "other.ml");
  Alcotest.(check (option int)) "new read keeps the destination line" (Some 7)
    state.code_target_line
;;

let test_file_recovery_preserves_nested_readers () =
  List.iter (fun (had_content, nested_first) ->
    let state = create_state ~workspace:"" ~port:0 ~refresh_interval:0. () in
    let initial, opened = start_read ~equal:String.equal state.code_file "source.ml" in
    state.code_file <- initial;
    if had_content then
      Code_results.apply_file state opened (Ok "let first = 1\nlet second = 2")
    else state.code_target_line <- Some 2;
    state.code_file_cursor <- (if had_content then 1 else 0);
    state.code_file_scroll <- (if had_content then 1 else 0);
    state.code_file_hscroll <- 3;
    state.code_focus_file <- Left_pane;
    suspend_workspace_readings state;
    let reading, recovered = start_read ~equal:String.equal state.code_file "source.ml" in
    state.code_file <- reading;
    let history, history_request = start_read ~equal:code_scope_path_equal
        state.code_history (state.code_scope, "source.ml") in
    state.code_history <- history;
    state.code_history_open <- true;
    let diff, diff_request = start_read ~equal:String.equal state.code_diff "source.ml" in
    state.code_diff <- diff;
    state.code_diff_open <- true;
    let blame, blame_request = start_read ~equal:String.equal state.code_blame "source.ml" in
    state.code_blame <- blame;
    let lsp = match Code_results.start_lsp_question ~line:2 state ~question:"hover" ~symbol:"second" with
      | Some request -> request | None -> Alcotest.fail "recovered LSP did not start" in
    let complete_nested () =
      Code_results.apply_history state history_request
        (Ok {chl_entries=[]; chl_git_error=None; chl_activity_note="recovered history"});
      Code_results.apply_diff state diff_request (Error "recovered diff refusal");
      Code_results.apply_blame state blame_request (Ok []);
      ignore (Code_results.apply_lsp_answer state lsp
        (Ok (Decode.Lsp_hover (Some "recovered hover")))) in
    if nested_first then complete_nested ();
    Code_results.apply_file ~intent:Refresh_code_file state recovered
      (Ok "let first = 3\nlet second = 4");
    if not nested_first then complete_nested ();
    Alcotest.(check bool) "history and diff stay open in either completion order" true
      (state.code_history_open && state.code_diff_open);
    Alcotest.(check bool) "recovered history remains visible" true
      (match Fetched.current state.code_history with
       | Some (_, Ready {chl_activity_note="recovered history";_}) -> true | _ -> false);
    Alcotest.(check bool) "recovered diff refusal remains visible" true
      (match Fetched.current state.code_diff with
       | Some (_, Failed "recovered diff refusal") -> true | _ -> false);
    Alcotest.(check bool) "blame completion retains its owner" true
      (match Fetched.current state.code_blame with Some (_, Ready []) -> true | _ -> false);
    Alcotest.(check (option string)) "file refresh does not erase a recovered hover"
      (Some "second: recovered hover") state.code_lsp_note;
    Alcotest.(check bool) "same file keeps cursor, scroll, horizontal offset and focus" true
      (state.code_file_cursor=1 && state.code_file_scroll=1
       && state.code_file_hscroll=3 && state.code_focus_file=Left_pane);
    Alcotest.(check (option int)) "first interrupted load consumes its target line once"
      None state.code_target_line;
    let short, shortened = start_read ~equal:String.equal state.code_file "source.ml" in
    state.code_file <- short;
    Code_results.apply_file ~intent:Refresh_code_file state shortened (Ok "x");
    Alcotest.(check bool) "shorter content clamps both row and horizontal coordinates" true
      (state.code_file_cursor=0 && state.code_file_scroll=0 && state.code_file_hscroll=0);
    let next, different_file = start_read ~equal:String.equal state.code_file "other.ml" in
    state.code_file <- next;
    Code_results.apply_file state different_file (Ok "let other = 0");
    Alcotest.(check bool) "new file still closes old nested readers" true
      (not state.code_history_open && not state.code_diff_open
       && Option.is_none (Fetched.current state.code_blame));
    Alcotest.(check int) "new file opens at its own first line" 0 state.code_file_cursor)
    [false, false; false, true; true, false; true, true]
;;

let test_lsp_replies_belong_to_their_source_reading () =
  let state = create_state ~workspace:"" ~port:0 ~refresh_interval:0. () in
  let read path =
    let next, request = start_read ~equal:String.equal state.code_file path in
    state.code_file <- next;
    Code_results.apply_file state request (Ok "let first = 1\nlet second = 2")
  in
  let ask question =
    match Code_results.start_lsp_question state ~question ~symbol:"first" with
    | Some request -> request
    | None -> Alcotest.fail "question did not start"
  in
  let location : Decode.lsp_location =
    {ll_path = "destination.ml"; ll_inside = true; ll_line = 5} in
  let rejected request result =
    let before = state.code_file_cursor, state.code_target_line, state.code_lsp_note,
                 state.code_jump_back, state.code_lsp_query in
    Alcotest.(check bool) "stale reply has no followup" true
      (Code_results.apply_lsp_answer state request result = Code_results.No_followup);
    Alcotest.(check bool) "stale reply changes no note, jump, target or query" true
      (before = (state.code_file_cursor, state.code_target_line, state.code_lsp_note,
                 state.code_jump_back, state.code_lsp_query))
  in
  read "source.ml";
  let from_source = ask "definition" in
  read "other.ml";
  rejected from_source (Ok (Decode.Lsp_locations [location]));
  read "source.ml";
  let from_project = ask "definition" in
  let same_scope_file = Option.get (Fetched.current_request state.code_file) in
  state.code_lsp_note <- Some "current query";
  state.code_target_line <- Some 7;
  set_code_scope state Code_scope_project;
  Alcotest.(check bool) "same scope preserves the source reading token" true
    (match Fetched.current_request state.code_file with
     | Some current -> Fetched.same_request ~equal:String.equal same_scope_file current
     | None -> false);
  Alcotest.(check bool) "same scope preserves the in-flight query" true
    (Fetched.is_current ~equal:code_lsp_query_equal state.code_lsp_query from_project);
  Alcotest.(check (option string)) "same scope preserves the current note" (Some "current query")
    state.code_lsp_note;
  Alcotest.(check (option int)) "same scope preserves the current target" (Some 7)
    state.code_target_line;
  set_code_scope state (Code_scope_keeper "alpha");
  Alcotest.(check bool) "new scope cannot reuse the old source reading" true
    (Option.is_none (Fetched.current_request state.code_file));
  Alcotest.(check bool) "new query waits for a read belonging to the new scope" true
    (Option.is_none (Code_results.start_lsp_question state ~question:"definition" ~symbol:"first"));
  Alcotest.(check (option string)) "scope change clears obsolete LSP note" None state.code_lsp_note;
  Alcotest.(check (option int)) "scope change clears obsolete jump target" None state.code_target_line;
  rejected from_project (Error "project server failed");
  read "source.ml";
  let new_scope_query = ask "hover" in
  ignore (Code_results.apply_lsp_answer state new_scope_query
            (Ok (Decode.Lsp_hover (Some "keeper reading"))));
  Alcotest.(check (option string)) "same path newly read in the new scope accepts its own answer"
    (Some "first: keeper reading") state.code_lsp_note;
  set_code_scope state Code_scope_project;
  rejected from_project (Ok (Decode.Lsp_locations [location]));
  read "source.ml";
  let before_same_path = ask "definition" in
  state.code_file <- Fetched.clear state.code_file;
  read "source.ml";
  rejected before_same_path (Ok (Decode.Lsp_locations [location]));
  let first = ask "definition" in
  Alcotest.(check bool) "same in-flight question is not dispatched twice" true
    (Option.is_none (Code_results.start_lsp_question state ~question:"definition" ~symbol:"first"));
  let latest = ask "hover" in
  rejected first (Error "superseded server error");
  rejected first (Ok (Decode.Lsp_locations [location]));
  Alcotest.(check bool) "latest answer settles its own query" true
    (Code_results.apply_lsp_answer state latest (Ok (Decode.Lsp_hover (Some "current hover")))
     = Code_results.No_followup);
  Alcotest.(check (option string)) "only current hover is shown" (Some "first: current hover")
    state.code_lsp_note;
  let repeated = ask "hover" in
  rejected latest (Error "old duplicate answer");
  ignore (Code_results.apply_lsp_answer state repeated (Error "actual current error"));
  Alcotest.(check (option string)) "current error is shown" (Some "first: actual current error")
    state.code_lsp_note
;;

let test_interrupted_new_file_open_resets_old_readers () =
  let state = create_state ~workspace:"" ~port:0 ~refresh_interval:0. () in
  let old, old_request = start_read ~equal:String.equal state.code_file "old.ml" in
  state.code_file <- old;
  Code_results.apply_file state old_request (Ok "let old = 1");
  let history, _ = start_read ~equal:code_scope_path_equal state.code_history
      (state.code_scope, "old.ml") in
  state.code_history <- history;
  state.code_history_open <- true;
  let diff, _ = start_read ~equal:String.equal state.code_diff "old.ml" in
  state.code_diff <- diff;
  state.code_diff_open <- true;
  state.code_file_cursor <- 5;
  state.code_file_scroll <- 5;
  state.code_focus_file <- Left_pane;
  let next, _ = start_read ~equal:String.equal state.code_file "new.ml" in
  state.code_file <- next;
  state.code_file_resume_intent <- Open_code_file;
  suspend_workspace_readings state;
  Alcotest.(check bool) "retired new selection keeps open intent" true
    (state.code_file_resume_intent = Open_code_file);
  let reading, request = start_read ~equal:String.equal state.code_file "new.ml" in
  state.code_file <- reading;
  Code_results.apply_file ~intent:state.code_file_resume_intent state request (Ok "let new_value = 2");
  Alcotest.(check bool) "new content closes previous file readers and resets navigation" true
    (not state.code_history_open && not state.code_diff_open
     && state.code_file_cursor = 0 && state.code_file_scroll = 0
     && state.code_focus_file = Right_pane);
  Alcotest.(check bool) "later recovery refreshes completed file" true
    (state.code_file_resume_intent = Refresh_code_file)
;;

let () =
  Alcotest.run
    "masc-tui-workspace-entries"
    [ ( "count label"
      , [] )
    ; ( "activity"
      , [ Alcotest.test_case "refresh preserves the visible Enter target" `Quick
            test_activity_refresh_reconciles_visible_selection
        ; Alcotest.test_case "failed file cannot retain old overlays" `Quick
            test_activity_file_starts_without_old_overlays
        ] )
    ; ( "reply navigation"
      , [ Alcotest.test_case "late reply and definitions preserve current content" `Quick
            test_file_reply_and_lsp_navigation_share_current_content
        ; Alcotest.test_case "interrupted new file opens reset old readers" `Quick
            test_interrupted_new_file_open_resets_old_readers
        ; Alcotest.test_case "file recovery preserves nested readers" `Quick
            test_file_recovery_preserves_nested_readers
        ; Alcotest.test_case "LSP replies belong to their source reading" `Quick
            test_lsp_replies_belong_to_their_source_reading ] )
    ; ( "scope"
      , [ Alcotest.test_case "a shared path is not a shared request" `Quick
            test_a_shared_path_is_not_a_shared_request
        ; Alcotest.test_case "a reply from the scope just left is dropped" `Quick
            test_a_reply_from_the_scope_just_left_is_dropped
        ; Alcotest.test_case "moving before the listing answers asks for the new directory" `Quick
            test_moving_before_the_listing_answers_asks_for_the_new_directory
        ] )
    ]
;;
