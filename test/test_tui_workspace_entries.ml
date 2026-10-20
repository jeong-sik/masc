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

let confirm_code_workspace state =
  state.server_identity <- Some
    { Decode.sid_version = "test"; sid_binary_commit = "test";
      sid_binary_commit_age_s = None; sid_base_path = Masc.Tui_decode.Canonical_path.of_path "/workspace";
      sid_masc_root = Masc.Tui_decode.Canonical_path.of_path "/workspace/.masc"; sid_executable_in_worktree = None;
      sid_state_ready = Some true; sid_uptime = None; sid_sse_clients = None;
      sid_gc = None; sid_scheduler = None };
  state.view <- Code

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
  confirm_code_workspace state;
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
    Code_results.apply_lsp_answer state request (Ok (Decode.Lsp_locations [location]));
    Code_results.take_ready_lsp_locations state ~input_pending:false
  in
  Alcotest.(check bool) "same-file definition requests reveal, not another load" true
    (answer (location "new.ml" true 1) = Code_results.Reveal_cursor);
  Alcotest.(check int) "definition selects its line" 0 state.code_file_cursor;
  let jumps = List.length state.code_jump_back in
  Alcotest.(check bool) "outside definition stays on current content" true
    (answer (location "stdlib.ml" false 4) = Code_results.No_followup);
  Alcotest.(check int) "outside definition does not add a back entry" jumps
    (List.length state.code_jump_back);
  (match answer (location "other.ml" true 7) with
   | Code_results.Read_location_file (owner, request) ->
       check_string "different file request" "other.ml" (Fetched.request_key request);
       Alcotest.(check int) "owned destination keeps its requested line" 6 owner.cno_destination.cj_cursor
   | Code_results.No_followup | Code_results.Choose_location | Code_results.Reveal_cursor ->
       Alcotest.fail "different-file location did not request an owned read");
  Alcotest.(check (option int)) "source has no premature jump target" None state.code_target_line;
  Alcotest.(check int) "pending location has not added a history entry" jumps
    (List.length state.code_jump_back)
;;

let test_file_recovery_preserves_nested_readers () =
  List.iter (fun (had_content, nested_first) ->
    let state = create_state ~workspace:"" ~port:0 ~refresh_interval:0. () in
    confirm_code_workspace state;
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
  confirm_code_workspace state;
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
    Code_results.apply_lsp_answer state request result;
    Alcotest.(check bool) "stale reply has no deferred location" true
      (Option.is_none state.code_location_offer);
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
  Code_results.apply_lsp_answer state latest (Ok (Decode.Lsp_hover (Some "current hover")));
  Alcotest.(check bool) "latest answer settles its own query" false
    (Fetched.in_flight state.code_lsp_query);
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

let finder_fixture () =
  let state = create_state ~workspace:"" ~port:0 ~refresh_interval:0. () in
  confirm_code_workspace state;
  state.code_scope <- Code_scope_repo "example";
  state.code_dir <- "src";
  let file, request = start_read ~equal:String.equal state.code_file "src/old.ml" in
  state.code_file <- file;
  Code_results.apply_file state request (Ok "let a = 1\nlet b = 2\nlet c = 3");
  state.code_file_cursor <- 2;
  state.code_file_scroll <- 2;
  let origin = {cfo_workspace=state.workspace_authority;
    cfo_reading=state.workspace_read_authority;
    cfo_scope=state.code_scope; cfo_dir=state.code_dir;
    cfo_file=Fetched.current_request state.code_file} in
  state.palette_open <- true;
  state.palette_mode <- Palette_files origin;
  let catalog, ticket = start_read ~equal:code_scope_path_equal state.code_catalog
      (origin.cfo_scope, origin.cfo_dir) in
  state.code_catalog <- catalog;
  Code_results.apply_catalog state ticket
    (Ok {Decode.wfc_root=""; wfc_files=["lib/new.ml"]});
  state, origin

let finder_select state path =
  let reading, request = start_read ~equal:code_scope_path_equal state.code_finder_file
      (state.code_scope, path) in
  state.code_finder_file <- reading;
  request

let test_finder_commits_navigation_only_after_success () =
  let state, _ = finder_fixture () in
  let before = state.code_file in
  let request = finder_select state "lib/new.ml" in
  Alcotest.(check bool) "pending read retains original file" true (before == state.code_file);
  Alcotest.(check int) "pending read retains cursor" 2 state.code_file_cursor;
  Alcotest.(check bool) "successful owned read commits once" true
    (Code_results.apply_found_file state request (Ok "let new_value = 4"));
  Alcotest.(check (option string)) "new file" (Some "lib/new.ml")
    (Fetched.current_key state.code_file);
  check_string "new containing directory" "lib" state.code_dir;
  Alcotest.(check bool) "successful selection closes finder" false state.palette_open;
  Alcotest.(check bool) "jump back retains original scope, file and position" true
    (match state.code_jump_back with
     | [target] -> target.cj_scope = Code_scope_repo "example" && target.cj_dir = "src"
         && target.cj_file = Some "src/old.ml" && target.cj_cursor = 2 && target.cj_scroll = 2
     | [] | _ :: _ -> false);
  Alcotest.(check bool) "duplicate completion cannot reopen" false
    (Code_results.apply_found_file state request (Ok "different bytes"))

let test_finder_failure_and_cancel_preserve_original () =
  let state, origin = finder_fixture () in
  let before = state.code_file in
  let failed = finder_select state "lib/new.ml" in
  Alcotest.(check bool) "failed read does not navigate" false
    (Code_results.apply_found_file state failed (Error "file disappeared"));
  Alcotest.(check bool) "failure retains file and cursor" true
    (before == state.code_file && state.code_file_cursor = 2 && state.code_dir = "src");
  let cancelled = finder_select state "lib/new.ml" in
  close_code_finder state;
  state.palette_open <- true;
  state.palette_mode <- Palette_files origin;
  let replacement = finder_select state "lib/new.ml" in
  Alcotest.(check bool) "same-path reopen does not borrow cancelled generation" false
    (Code_results.apply_found_file state cancelled (Ok "cancelled bytes"));
  Alcotest.(check bool) "late cleanup did not retire replacement" true
    (Fetched.is_current ~equal:code_scope_path_equal state.code_finder_file replacement);
  Alcotest.(check bool) "cancel retained original file" true (before == state.code_file)

let test_finder_does_not_borrow_changed_owners () =
  List.iter
    (fun change ->
      let state, _ = finder_fixture () in
      let request = finder_select state "lib/new.ml" in
      change state;
      let before = state.code_file in
      Alcotest.(check bool) "late read cannot commit under a changed owner" false
        (Code_results.apply_found_file state request (Ok "late bytes"));
      Alcotest.(check bool) "current file and navigation untouched" true
        (before == state.code_file && state.code_jump_back = []))
    [ (fun state -> set_code_scope state (Code_scope_repo "other"))
    ; (fun state -> state.server_identity <- None)
    ; (fun state -> state.code_dir <- "another")
    ; (fun state ->
        let next, _ = start_read ~equal:String.equal state.code_file "src/old.ml" in
        state.code_file <- next)
    ; (fun state -> state.view <- Repositories)
    ]

let test_finder_success_yields_to_pending_input () =
  let state, _ = finder_fixture () in
  let before = state.code_file in
  let request = finder_select state "lib/new.ml" in
  Alcotest.(check bool) "publication yields to a queued key or paste" false
    (Code_results.apply_found_file ~input_pending:true state request (Ok "let new_value = 4"));
  Alcotest.(check bool) "original file remains while input is pending" true
    (before == state.code_file && state.palette_open);
  Alcotest.(check bool) "an incomplete terminal sequence also defers" false
    (Code_results.take_ready_found_file state ~input_pending:true);
  close_code_finder state;
  Alcotest.(check bool) "Esc wins over already received success" false
    (Code_results.take_ready_found_file state ~input_pending:false);
  Alcotest.(check bool) "Esc retained original file" true (before == state.code_file);
  let state, _ = finder_fixture () in
  let request = finder_select state "lib/new.ml" in
  ignore (Code_results.apply_found_file ~input_pending:true state request (Ok "let next = 4"));
  Alcotest.(check bool) "success resumes after input has drained" true
    (Code_results.take_ready_found_file state ~input_pending:false);
  Alcotest.(check bool) "ready result is consumed once" false
    (Code_results.take_ready_found_file state ~input_pending:false)

let test_catalog_decoder_keeps_identity_and_rejects_missing_data () =
  let path = "repos/example/새 파일\n이름.ml" in
  (match Decode.decode_workspace_file_catalog
      (`Assoc ["root", `String "repos/example"; "files", `List [`String path]]) with
   | Error detail -> Alcotest.fail detail
   | Ok catalog -> Alcotest.(check (list string)) "exact file identity" [path] catalog.wfc_files);
  List.iter
    (fun json -> match Decode.decode_workspace_file_catalog json with
     | Error _ -> ()
     | Ok _ -> Alcotest.fail "malformed response became a usable catalog")
    [ `Assoc ["root", `String ""]
    ; `Assoc ["root", `String ""; "files", `List [`Int 1]]
    ; `Assoc ["root", `String ""; "files", `List [`String ""]]
    ]

let test_finder_ready_content_cannot_borrow_reconfirmed_authority () =
  let state, _ = finder_fixture () in
  let request = finder_select state "lib/new.ml" in
  ignore (Code_results.apply_found_file ~input_pending:true state request (Ok "old authority bytes"));
  let identity = state.server_identity in
  suspend_workspace_readings state;
  state.server_identity <- identity;
  state.workspace_identity <- Workspace_identity_match;
  Alcotest.(check bool) "same workspace has been confirmed again" true (server_authority_ready state);
  let before = state.code_file in
  Alcotest.(check bool) "ready old content cannot navigate after read authority loss" false
    (Code_results.take_ready_found_file state ~input_pending:false);
  Alcotest.(check bool) "original file is preserved" true (before == state.code_file);
  match code_finder_catalog state with
  | Fetched.Absent -> ()
  | Fetched.Loading | Fetched.Ready _ | Fetched.Stale _ | Fetched.Failed _ ->
      Alcotest.fail "old catalog borrowed the new read authority"

let return_fixture () =
  let state, _ = finder_fixture () in
  close_code_finder state;
  state.code_file_cursor <- 2;
  state.code_file_scroll <- 1;
  state.code_file_hscroll <- 6;
  state.code_cursor <- 7;
  state.code_focus_file <- Left_pane;
  Code_results.push_code_jump state;
  set_code_scope state (Code_scope_keeper "other");
  state.code_dir <- "lib";
  let file, request = start_read ~equal:String.equal state.code_file "lib/new.ml" in
  state.code_file <- file;
  Code_results.apply_file state request (Ok "let current = true");
  state

let start_return_read state =
  match Code_results.start_return state with
  | Code_results.Read_navigation_file (owner, request) -> owner, request
  | Code_results.No_return | Code_results.Return_committed ->
      Alcotest.fail "expected an owned historical file read"

let test_return_restores_reading_after_success () =
  let state = return_fixture () in
  let current = state.code_file and history = state.code_jump_back in
  let owner, request = start_return_read state in
  check_string "request names the historical file" "src/old.ml" (Fetched.request_key request);
  Alcotest.(check bool) "destination retains its own repository scope" true
    ((List.hd owner.cno_history).cj_scope = Code_scope_repo "example");
  Alcotest.(check bool) "pending read preserves current location and history" true
    (state.code_file == current && state.code_jump_back == history
     && state.code_scope = Code_scope_keeper "other" && state.code_dir = "lib");
  Alcotest.(check bool) "repeated B shares pending return" true
    (match Code_results.start_return state with
     | Code_results.No_return -> true
     | Code_results.Return_committed | Code_results.Read_navigation_file _ -> false);
  Code_results.apply_file ~intent:(Navigate_code_file owner) state request
    (Ok "let first_line = 1\nlet second_line = 2\nlet third_line = 3");
  Alcotest.(check bool) "publication leaves current file intact" true (state.code_file == current);
  Alcotest.(check bool) "queued input defers navigation" false
    (Code_results.take_ready_navigation_file state ~input_pending:true);
  Alcotest.(check bool) "idle commits success" true
    (Code_results.take_ready_navigation_file state ~input_pending:false);
  Alcotest.(check bool) "historical reading and all position axes restored" true
    (Fetched.current_key state.code_file = Some "src/old.ml"
     && state.code_scope = Code_scope_repo "example" && state.code_dir = "src"
     && state.code_file_cursor = 2 && state.code_file_scroll = 1
     && state.code_file_hscroll = 6 && state.code_cursor = 7
     && state.code_focus_file = Left_pane && state.code_jump_back = []);
  Alcotest.(check bool) "success is consumed only once" false
    (Code_results.take_ready_navigation_file state ~input_pending:false)

let test_return_failure_retry_and_cancel () =
  let state = return_fixture () in
  let current = state.code_file and history = state.code_jump_back in
  let old_owner, old_request = start_return_read state in
  Code_results.apply_file ~intent:(Navigate_code_file old_owner) state old_request (Error "gone");
  Alcotest.(check bool) "failure retains reading and unconsumed history" true
    (state.code_file == current && state.code_jump_back == history
     && state.code_dir = "lib" && Option.is_none state.code_navigation);
  let owner, request = start_return_read state in
  Code_results.apply_file ~intent:(Navigate_code_file old_owner) state old_request (Ok "stale");
  Alcotest.(check bool) "old same-path generation cannot satisfy retry" false
    (Code_results.take_ready_navigation_file state ~input_pending:false);
  Code_results.apply_file ~intent:(Navigate_code_file owner) state request (Ok "retry");
  state.code_navigation <- None;
  Alcotest.(check bool) "cancellation wins over an already published success" false
    (Code_results.take_ready_navigation_file state ~input_pending:false);
  Alcotest.(check bool) "cancel leaves reading and history available" true
    (state.code_file == current && state.code_jump_back == history)

let test_return_owners_cannot_be_borrowed () =
  List.iter (fun change ->
    let state = return_fixture () in
    let owner, request = start_return_read state in
    Code_results.apply_file ~intent:(Navigate_code_file owner) state request (Ok "late content");
    change state;
    let current = state.code_file and history = state.code_jump_back in
    Alcotest.(check bool) "ready old return cannot navigate under a new owner" false
      (Code_results.take_ready_navigation_file state ~input_pending:false);
    Alcotest.(check bool) "replacement reading and history are preserved" true
      (state.code_file == current && state.code_jump_back == history))
    [ (fun state -> state.view <- Repositories)
    ; (fun state -> set_code_scope state Code_scope_project)
    ; (fun state -> state.code_dir <- "elsewhere")
    ; (fun state ->
        let next, _ = start_read ~equal:String.equal state.code_file "lib/replacement.ml" in
        state.code_file <- next)
    ; (fun state -> Code_results.push_code_jump state)
    ; (fun state ->
        let identity = state.server_identity in
        suspend_workspace_readings state;
        state.server_identity <- identity;
        state.workspace_identity <- Workspace_identity_match)
    ]

let test_return_clamps_changed_content_and_restores_current_file () =
  let state = return_fixture () in
  let owner, request = start_return_read state in
  Code_results.apply_file ~intent:(Navigate_code_file owner) state request (Ok "ab");
  ignore (Code_results.take_ready_navigation_file state ~input_pending:false);
  Alcotest.(check bool) "shorter file clamps cursor and both offsets" true
    (state.code_file_cursor = 0 && state.code_file_scroll = 0 && state.code_file_hscroll = 1);
  state.code_file_hscroll <- 1;
  Code_results.push_code_jump state;
  state.code_file_hscroll <- 0;
  state.code_focus_file <- Right_pane;
  Alcotest.(check bool) "readable current file restores without a read" true
    (match Code_results.start_return state with
     | Code_results.Return_committed -> true
     | Code_results.No_return | Code_results.Read_navigation_file _ -> false);
  Alcotest.(check bool) "current file restores pan and focus" true
    (state.code_file_hscroll = 1 && state.code_focus_file = Left_pane)

let test_return_to_tree_needs_no_file () =
  let state, _ = finder_fixture () in
  close_code_finder state;
  state.code_file <- Fetched.clear state.code_file;
  state.code_cursor <- 1;
  Code_results.push_code_jump state;
  let next, request = start_read ~equal:String.equal state.code_file "lib/new.ml" in
  state.code_file <- next;
  Code_results.apply_file state request (Ok "new");
  state.code_dir <- "lib";
  Alcotest.(check bool) "tree history commits without a file request" true
    (match Code_results.start_return state with
     | Code_results.Return_committed -> true
     | Code_results.No_return | Code_results.Read_navigation_file _ -> false);
  Alcotest.(check bool) "tree cursor and directory restored" true
    (state.code_dir = "src" && state.code_cursor = 1 && state.code_focus_file = Left_pane
     && Fetched.current_key state.code_file = None && state.code_jump_back = [])

let test_same_file_return_retires_an_ordinary_open_refresh () =
  List.iter (fun late_result ->
    let state, _ = finder_fixture () in
    close_code_finder state;
    state.code_file_cursor <- 2;
    state.code_file_scroll <- 1;
    state.code_file_hscroll <- 6;
    state.code_cursor <- 7;
    state.code_focus_file <- Left_pane;
    Code_results.push_code_jump state;
    let reading = Fetched.current state.code_file in
    state.code_file_cursor <- 0;
    state.code_file_scroll <- 0;
    state.code_file_hscroll <- 0;
    state.code_cursor <- 0;
    state.code_focus_file <- Right_pane;
    (* [launch_file_load] uses [start] and this intent even for a readable
       same-key file. [current] still exposes Ready while it is refreshing. *)
    let refreshing, ordinary = start_read ~equal:String.equal state.code_file "src/old.ml" in
    state.code_file <- refreshing;
    state.code_file_resume_intent <- Open_code_file;
    Alcotest.(check bool) "ordinary same-file open is really pending" true
      (Fetched.in_flight state.code_file);
    Alcotest.(check bool) "return uses visible reading without another file request" true
      (match Code_results.start_return state with
       | Code_results.Return_committed -> true
       | Code_results.No_return | Code_results.Read_navigation_file _ -> false);
    let returned = state.code_file in
    Alcotest.(check bool) "return retires the old ordinary callback" false
      (Fetched.is_current ~equal:String.equal state.code_file ordinary);
    Alcotest.(check bool) "return retains previously read content without a pending read" true
      (Fetched.current state.code_file = reading && not (Fetched.in_flight state.code_file));
    Code_results.apply_file ~intent:Open_code_file state ordinary late_result;
    Alcotest.(check bool) "late ordinary result cannot reset the restored reading" true
      (state.code_file == returned && state.code_file_cursor = 2
       && state.code_file_scroll = 1 && state.code_file_hscroll = 6
       && state.code_cursor = 7 && state.code_focus_file = Left_pane
       && state.code_jump_back = [] && Option.is_none state.code_navigation);
    Alcotest.(check bool) "authority recovery resumes the reading without an open reset" true
      (state.code_file_resume_intent = Refresh_code_file))
    [Ok "late replacement"; Error "late failure"]

let test_pending_return_retires_other_ordinary_file_reads () =
  List.iter (fun stale ->
    List.iter (fun late_result ->
      let state = return_fixture () in
      if stale then begin
        let refreshing, failed = start_read ~equal:String.equal state.code_file "lib/new.ml" in
        state.code_file <- refreshing;
        Code_results.apply_file ~intent:Refresh_code_file state failed (Error "unavailable")
      end else state.code_file <- Fetched.clear state.code_file;
      let refreshing, ordinary = start_read ~equal:String.equal state.code_file "lib/new.ml" in
      state.code_file <- refreshing;
      state.code_file_resume_intent <- Open_code_file;
      let history = state.code_jump_back in
      let owner, request = start_return_read state in
      let current = state.code_file in
      Alcotest.(check bool) "pending return retires ordinary source admission" false
        (Fetched.is_current ~equal:String.equal current ordinary);
      if stale then
        Alcotest.(check bool) "cancelling an ordinary retry retains its stale cause" true
          (match Fetched.current current with
           | Some (_, Fetched.Stale (_, "unavailable")) -> true
           | None | Some (_, (Fetched.Absent | Fetched.Loading | Fetched.Ready _
                            | Fetched.Stale _ | Fetched.Failed _)) -> false)
      else
        Alcotest.(check bool) "cancelled initial read has no invented content" true
          (match Fetched.current current with
           | Some (_, Fetched.Failed _) -> true
           | None | Some (_, (Fetched.Absent | Fetched.Loading | Fetched.Ready _
                            | Fetched.Stale _)) -> false);
      Code_results.apply_file ~intent:Open_code_file state ordinary late_result;
      Alcotest.(check bool) "late ordinary callback cannot alter the pending return's source" true
        (state.code_file == current && state.code_jump_back == history
         && Option.is_some state.code_navigation && state.code_dir = "lib");
      Code_results.apply_file ~intent:(Navigate_code_file owner) state request (Ok "returned");
      Alcotest.(check bool) "the separately owned return can still commit" true
        (Code_results.take_ready_navigation_file state ~input_pending:false))
      [Ok "late replacement"; Error "late failure"])
    [false; true]

let start_location_read state path line =
  let request = match Code_results.start_lsp_question state ~question:"definition" ~symbol:"target" with
    | Some request -> request | None -> Alcotest.fail "location question did not start" in
  let location : Decode.lsp_location = {ll_path=path; ll_inside=true; ll_line=line} in
  Code_results.apply_lsp_answer state request (Ok (Decode.Lsp_locations [location]));
  match Code_results.take_ready_lsp_locations state ~input_pending:false with
  | Code_results.Read_location_file (owner, request) -> owner, request
  | Code_results.No_followup | Code_results.Choose_location | Code_results.Reveal_cursor ->
      Alcotest.fail "expected an owned different-file location read"

let test_navigation_activity_preserves_settled_observations () =
  let state = return_fixture () in
  state.code_lsp_note <- Some "last language-server observation";
  let observation = state.code_lsp_note in
  let source = state.code_file and history = state.code_jump_back in
  let active owner request =
    match code_pending_navigation state with
    | Some (current, path) -> current == owner && path = Fetched.request_key request
    | None -> false in
  let owner, request = start_return_read state in
  Alcotest.(check bool) "accepted return retains the settled observation and source" true
    (active owner request && state.code_lsp_note == observation
     && state.code_file == source && state.code_jump_back == history);
  Code_results.apply_file ~intent:(Navigate_code_file owner) state request (Ok "received");
  Alcotest.(check bool) "received navigation still yields to queued input" false
    (Code_results.take_ready_navigation_file state ~input_pending:true);
  Alcotest.(check bool) "activity remains owned until destination admission" true
    (active owner request && state.code_lsp_note == observation);
  state.code_navigation <- None;
  Code_results.apply_file ~intent:(Navigate_code_file owner) state request (Error "late cancellation");
  Alcotest.(check bool) "cancellation retires activity without losing observed state" true
    (Option.is_none (code_pending_navigation state) && state.code_lsp_note == observation
     && state.code_file == source && state.code_jump_back == history);
  let retry_owner, retry = start_return_read state in
  Code_results.apply_file ~intent:(Navigate_code_file owner) state request (Ok "obsolete");
  Alcotest.(check bool) "an old success cannot settle the replacement" true
    (active retry_owner retry && state.code_lsp_note == observation);
  Code_results.apply_file ~intent:(Navigate_code_file retry_owner) state retry (Error "unavailable");
  let failure = state.code_lsp_note in
  Alcotest.(check bool) "failure ends activity and preserves source and history" true
    (Option.is_none (code_pending_navigation state) && Option.is_some failure
     && failure != observation && state.code_file == source && state.code_jump_back == history);
  let final_owner, final_request = start_return_read state in
  Alcotest.(check bool) "retry retains the observed failure while pending" true
    (active final_owner final_request && state.code_lsp_note == failure);
  Code_results.apply_file ~intent:(Navigate_code_file final_owner) state final_request
    (Ok "let a = 1\nlet b = 2\nlet c = 3");
  Alcotest.(check bool) "idle admits the destination" true
    (Code_results.take_ready_navigation_file state ~input_pending:false);
  Alcotest.(check bool) "admission ends activity and settles the historical source" true
    (Option.is_none (code_pending_navigation state) && Option.is_none state.code_lsp_note
     && Fetched.current_key state.code_file = Some "src/old.ml" && state.code_jump_back = [])

let test_navigation_activity_belongs_to_the_original_source () =
  let changes =
    [ (fun state -> state.code_navigation <- None)
    ; (fun state -> state.view <- Repositories)
    ; (fun state -> set_code_scope state Code_scope_project)
    ; (fun state -> state.code_dir <- "elsewhere")
    ; (fun state ->
        let path = match Fetched.current_key state.code_file with
          | Some path -> path | None -> Alcotest.fail "source file disappeared" in
        let file, _ = start_read ~equal:String.equal state.code_file path in
        state.code_file <- file)
    ; (fun state -> state.code_jump_back <- List.map (fun target -> target) state.code_jump_back)
    ; (fun state ->
        let identity = state.server_identity in
        suspend_workspace_readings state;
        state.server_identity <- identity;
        state.workspace_identity <- Workspace_identity_match)
    ] in
  List.iter (fun action -> List.iter (fun change ->
    let state = return_fixture () in
    let owner, request = match action with
      | Return_to_history -> start_return_read state
      | Follow_location -> start_location_read state "lib/target.ml" 3 in
    Alcotest.(check bool) "original source owns the pending action" true
      (match code_pending_navigation state with
       | Some (current, path) -> current == owner && current.cno_action = action
           && path = Fetched.request_key request
       | None -> false);
    Code_results.apply_file ~intent:(Navigate_code_file owner) state request (Ok "destination");
    change state;
    let source = state.code_file and history = state.code_jump_back in
    let observation = state.code_lsp_note in
    Alcotest.(check bool) "changed source cannot borrow pending activity" true
      (Option.is_none (code_pending_navigation state));
    Code_results.apply_file ~intent:(Navigate_code_file owner) state request (Error "late failure");
    Alcotest.(check bool) "changed source rejects the already received destination" false
      (Code_results.take_ready_navigation_file state ~input_pending:false);
    Alcotest.(check bool) "late work preserves current source, history and observation" true
      (state.code_file == source && state.code_jump_back == history
       && state.code_lsp_note == observation)) changes)
    [Return_to_history; Follow_location]

let test_location_commits_history_only_on_success () =
  let state, _ = finder_fixture () in
  close_code_finder state;
  state.code_file_hscroll <- 4;
  let current = state.code_file and history = state.code_jump_back in
  let owner, request = start_location_read state "lib/target.ml" 2 in
  Alcotest.(check bool) "pending location retains original file and history" true
    (state.code_file == current && state.code_jump_back == history && state.code_dir = "src");
  Alcotest.(check bool) "destination retains repository scope" true
    (owner.cno_destination.cj_scope = Code_scope_repo "example");
  Code_results.apply_file ~intent:(Navigate_code_file owner) state request
    (Ok "let first = 0\nlet target = 1\nlet last = 2");
  Alcotest.(check bool) "queued input precedes location success" false
    (Code_results.take_ready_navigation_file state ~input_pending:true);
  Alcotest.(check bool) "source still displayed while success is deferred" true (state.code_file == current);
  Alcotest.(check bool) "idle commits destination" true
    (Code_results.take_ready_navigation_file state ~input_pending:false);
  Alcotest.(check bool) "destination line and containing directory agree" true
    (Fetched.current_key state.code_file = Some "lib/target.ml" && state.code_dir = "lib"
     && state.code_file_cursor = 1 && state.code_file_scroll = 1 && state.code_file_hscroll = 0);
  Alcotest.(check bool) "successful location records the source position once" true
    (match state.code_jump_back with
     | [target] -> target.cj_file = Some "src/old.ml" && target.cj_cursor = 2
         && target.cj_scroll = 2 && target.cj_hscroll = 4 && target.cj_dir = "src"
     | [] | _ :: _ -> false);
  let owner, request = start_return_read state in
  Code_results.apply_file ~intent:(Navigate_code_file owner) state request
    (Ok "let a = 1\nlet b = 2\nlet c = 3");
  ignore (Code_results.take_ready_navigation_file state ~input_pending:false);
  Alcotest.(check bool) "B returns through the successfully recorded location" true
    (Fetched.current_key state.code_file = Some "src/old.ml" && state.code_file_cursor = 2
     && state.code_file_scroll = 2 && state.code_file_hscroll = 4 && state.code_jump_back = [])

let test_location_failure_cancel_and_replacement_preserve_source () =
  let state, _ = finder_fixture () in
  close_code_finder state;
  let current = state.code_file and history = state.code_jump_back in
  let old_owner, old_request = start_location_read state "lib/target.ml" 99 in
  Code_results.apply_file ~intent:(Navigate_code_file old_owner) state old_request (Error "missing file");
  Alcotest.(check bool) "failed location retains source and creates no history" true
    (state.code_file == current && state.code_jump_back == history && state.code_dir = "src");
  let owner, request = start_location_read state "lib/target.ml" 99 in
  Code_results.apply_file ~intent:(Navigate_code_file old_owner) state old_request (Ok "late old read");
  Alcotest.(check bool) "old same-path location cannot complete the retry" false
    (Code_results.take_ready_navigation_file state ~input_pending:false);
  Code_results.apply_file ~intent:(Navigate_code_file owner) state request (Ok "short");
  state.code_navigation <- None;
  Alcotest.(check bool) "cancelled ready location cannot navigate" false
    (Code_results.take_ready_navigation_file state ~input_pending:false);
  Alcotest.(check bool) "cancel retains source and history" true
    (state.code_file == current && state.code_jump_back == history);
  let owner, request = start_location_read state "lib/target.ml" 99 in
  Code_results.apply_file ~intent:(Navigate_code_file owner) state request (Ok "short");
  ignore (Code_results.take_ready_navigation_file state ~input_pending:false);
  Alcotest.(check int) "destination beyond new EOF clamps to actual content" 0 state.code_file_cursor

let test_return_replaces_pending_location_without_consuming_history () =
  let state = return_fixture () in
  let location_owner, location_request = start_location_read state "lib/target.ml" 3 in
  let current = state.code_file and history = state.code_jump_back in
  let return_owner, _ = start_return_read state in
  Alcotest.(check bool) "B owns a return rather than sharing an unrelated location" true
    (return_owner.cno_action = Return_to_history);
  Code_results.apply_file ~intent:(Navigate_code_file location_owner) state location_request (Ok "obsolete");
  Alcotest.(check bool) "late location cannot replace B's request" true
    (match state.code_navigation with
     | Some reading -> reading.cnr_owner == return_owner
     | None -> false);
  Alcotest.(check bool) "replacement keeps reading and return history" true
    (state.code_file == current && state.code_jump_back == history)

let test_location_cannot_borrow_changed_authority () =
  List.iter (fun change ->
    let state, _ = finder_fixture () in
    close_code_finder state;
    let owner, request = start_location_read state "lib/target.ml" 3 in
    Code_results.apply_file ~intent:(Navigate_code_file owner) state request (Ok "destination");
    change state;
    let current = state.code_file and history = state.code_jump_back in
    Alcotest.(check bool) "changed owner refuses an already received location" false
      (Code_results.take_ready_navigation_file state ~input_pending:false);
    Alcotest.(check bool) "changed source and history remain intact" true
      (state.code_file == current && state.code_jump_back == history))
    [ (fun state -> state.view <- Repositories)
    ; (fun state -> set_code_scope state (Code_scope_repo "other"))
    ; (fun state -> ignore (Code_results.start_lsp_question state ~question:"hover" ~symbol:"another"))
    ; (fun state ->
        let identity = state.server_identity in
        suspend_workspace_readings state;
        state.server_identity <- identity;
        state.workspace_identity <- Workspace_identity_match)
    ]

let test_locations_retire_ordinary_source_callbacks () =
  List.iter (fun same_file ->
    List.iter (fun late_result ->
      let state, _ = finder_fixture () in
      close_code_finder state;
      state.code_file_hscroll <- 4;
      let next, ordinary = start_read ~equal:String.equal state.code_file "src/old.ml" in
      state.code_file <- next;
      state.code_file_resume_intent <- Open_code_file;
      let query = match Code_results.start_lsp_question state ~question:"definition" ~symbol:"target" with
        | Some request -> request | None -> Alcotest.fail "question did not start" in
      let location : Decode.lsp_location = {
        ll_path=(if same_file then "src/old.ml" else "lib/target.ml"); ll_inside=true; ll_line=1 } in
      Code_results.apply_lsp_answer state query (Ok (Decode.Lsp_locations [location]));
      let followup = Code_results.take_ready_lsp_locations state ~input_pending:false in
      let before = state.code_file, state.code_file_cursor, state.code_file_scroll,
        state.code_file_hscroll, state.code_focus_file, state.code_jump_back in
      Code_results.apply_file ~intent:Open_code_file state ordinary late_result;
      Alcotest.(check bool) "late ordinary source cannot reset location or pending source" true
        (before = (state.code_file, state.code_file_cursor, state.code_file_scroll,
          state.code_file_hscroll, state.code_focus_file, state.code_jump_back));
      Alcotest.(check bool) "recovery retains Refresh rather than obsolete Open" true
        (state.code_file_resume_intent = Refresh_code_file);
      match followup with
      | Code_results.Reveal_cursor ->
          Alcotest.(check bool) "same file selects the destination and resets pan" true
            (same_file && state.code_file_cursor = 0 && state.code_file_hscroll = 0)
      | Code_results.Read_location_file (owner, request) ->
          Alcotest.(check bool) "different file uses a distinct owner" false same_file;
          Code_results.apply_file ~intent:(Navigate_code_file owner) state request (Ok "target");
          ignore (Code_results.take_ready_navigation_file state ~input_pending:false);
          Alcotest.(check (option string)) "owned location still completes" (Some "lib/target.ml")
            (Fetched.current_key state.code_file)
      | Code_results.No_followup | Code_results.Choose_location -> Alcotest.fail "location unexpectedly refused")
      [Ok "late reset"; Error "late failure"])
    [true; false]

let offered_locations state locations =
  let query = match Code_results.start_lsp_question state ~question:"references" ~symbol:"target" with
    | Some query -> query | None -> Alcotest.fail "location question did not start" in
  Code_results.apply_lsp_answer state query (Ok (Decode.Lsp_locations locations));
  let offer = match state.code_location_offer with
    | Some offer -> offer | None -> Alcotest.fail "current locations were not staged" in
  query, offer

let location path line : Decode.lsp_location =
  {ll_path=path; ll_line=line; ll_inside=true}

let ask_pending state question =
  match Code_results.start_lsp_question state ~question ~symbol:"target" with
  | Some request -> request
  | None -> Alcotest.fail "question did not start"

let test_lsp_pending_status_follows_request_lifetime () =
  List.iter (fun result ->
    let state, _ = finder_fixture () in
    close_code_finder state;
    state.code_lsp_note <- Some "previous observation";
    let request = ask_pending state "references" in
    Alcotest.(check bool) "accepted question clears the previous settled observation" true
      (Option.is_none state.code_lsp_note);
    Alcotest.(check bool) "pending query names the accepted request" true
      (Option.equal code_lsp_query_equal (Some (Fetched.request_key request))
         (code_lsp_pending_query state));
    Code_results.apply_lsp_answer state request result;
    Alcotest.(check bool) "success, failure or a staged location offer is no longer pending" true
      (Option.is_none (code_lsp_pending_query state)))
    [Ok (Decode.Lsp_hover (Some "hover observation")); Error "language server failed";
     Ok (Decode.Lsp_locations []);
     Ok (Decode.Lsp_locations [location "one.ml" 1; location "two.ml" 2])];
  let state, _ = finder_fixture () in
  close_code_finder state;
  let cancelled = ask_pending state "references" in
  Code_results.retire_lsp_input state;
  Alcotest.(check bool) "input cancellation removes pending status" true
    (Option.is_none (code_lsp_pending_query state) && Option.is_none state.code_lsp_note);
  Code_results.apply_lsp_answer state cancelled (Error "late error");
  Alcotest.(check bool) "late cancelled error cannot restore pending status or a note" true
    (Option.is_none (code_lsp_pending_query state) && Option.is_none state.code_lsp_note);
  ignore (offered_locations state [location "one.ml" 1; location "two.ml" 2]);
  ignore (Code_results.take_ready_lsp_locations state ~input_pending:false);
  close_code_finder state;
  Alcotest.(check bool) "closing received choices leaves no pending question" true
    (Option.is_none (code_lsp_pending_query state)
     && Option.is_none (Fetched.current_request state.code_lsp_query))

let test_lsp_pending_status_includes_refresh_and_retry () =
  List.iter (fun result ->
    let state, _ = finder_fixture () in
    close_code_finder state;
    let settled = ask_pending state "hover" in
    Code_results.apply_lsp_answer state settled result;
    let refreshed = ask_pending state "hover" in
    Alcotest.(check bool) "same-question Ready refresh or failed retry remains pending" true
      (Fetched.in_flight state.code_lsp_query && Option.is_some (code_lsp_pending_query state)
       && not (Fetched.same_request ~equal:code_lsp_query_equal settled refreshed)
       && Option.is_none state.code_lsp_note);
    Alcotest.(check bool) "Ready refresh retains its value while failed Poll retry starts Loading" true
      (match Fetched.current state.code_lsp_query with
       | Some (_, Fetched.Ready ()) -> Result.is_ok result
       | Some (_, Fetched.Loading) -> Result.is_error result
       | None | Some (_, (Fetched.Absent | Fetched.Failed _ | Fetched.Stale _)) -> false);
    let note = Some "another observation" in
    state.code_lsp_note <- note;
    Alcotest.(check bool) "suppressed duplicate does not mutate an existing note" true
      (Option.is_none (Code_results.start_lsp_question state ~question:"hover" ~symbol:"target")
       && state.code_lsp_note == note);
    Code_results.apply_lsp_answer state refreshed result;
    Alcotest.(check bool) "settling refresh or retry removes pending status" true
      (Option.is_none (code_lsp_pending_query state));
    state.code_file <- Fetched.clear state.code_file;
    state.code_lsp_note <- note;
    Alcotest.(check bool) "refused question without a source does not erase its note" true
      (Option.is_none (Code_results.start_lsp_question state ~question:"hover" ~symbol:"target")
       && state.code_lsp_note == note && Option.is_none (code_lsp_pending_query state)))
    [Ok (Decode.Lsp_hover (Some "hover observation")); Error "language server failed"]

let test_lsp_pending_status_belongs_to_the_current_source () =
  let state, _ = finder_fixture () in
  close_code_finder state;
  let old = ask_pending state "references" in
  let replacement = ask_pending state "hover" in
  Code_results.apply_lsp_answer state old (Ok (Decode.Lsp_hover (Some "obsolete")));
  Alcotest.(check bool) "replaced question cannot settle the current pending query" true
    (Option.equal code_lsp_query_equal (Some (Fetched.request_key replacement))
       (code_lsp_pending_query state) && Option.is_none state.code_lsp_note);
  List.iter (fun change ->
    let state, _ = finder_fixture () in
    close_code_finder state;
    let request = ask_pending state "references" in
    change state;
    Alcotest.(check bool) "changed authority, view, scope, directory or file cannot show pending" true
      (Option.is_none (code_lsp_pending_query state));
    Code_results.apply_lsp_answer state request (Error "obsolete failure");
    Alcotest.(check bool) "the same owner guard refuses the late answer" true
      (Option.is_none state.code_lsp_note))
    [ (fun state -> state.server_identity <- None)
    ; (fun state -> state.workspace_authority <-
         (let Workspace_authority generation = state.workspace_authority in
          Workspace_authority (generation + 1)))
    ; (fun state -> state.workspace_read_authority <- ref ())
    ; (fun state -> state.view <- Repositories)
    ; (fun state -> state.code_scope <- Code_scope_project)
    ; (fun state -> state.code_dir <- "other")
    ; (fun state ->
        let file, _ = start_read ~equal:String.equal state.code_file "src/old.ml" in
        state.code_file <- file)
    ; suspend_workspace_readings
    ]

let resume_question_after_workspace_confirmation state =
  let identity = state.server_identity in
  state.server_identity <- None;
  suspend_workspace_readings state;
  state.server_identity <- identity;
  state.workspace_identity <- Workspace_identity_match;
  (* Code recovery captures the question key before starting the file refresh,
     then reissues the question against that refresh's source ticket. *)
  let question = Fetched.current_key state.code_lsp_query in
  let path = match Fetched.current_key state.code_file with
    | Some path -> path | None -> Alcotest.fail "recovery lost the source file" in
  let file, file_request = start_read ~equal:String.equal state.code_file path in
  state.code_file <- file;
  let resumed = Option.bind question (fun query ->
    Code_results.start_lsp_question ~line:query.clq_line state
      ~question:query.clq_question ~symbol:query.clq_symbol) in
  Code_results.apply_file ~intent:Refresh_code_file state file_request
    (Ok "let a = 1\nlet b = 2\nlet c = 3");
  resumed

let test_cancelled_questions_do_not_resume_after_workspace_recovery () =
  List.iter (fun received ->
    let state, _ = finder_fixture () in
    close_code_finder state;
    let query = match Code_results.start_lsp_question state ~question:"references" ~symbol:"target" with
      | Some query -> query | None -> Alcotest.fail "question did not start" in
    let answer = Ok (Decode.Lsp_locations [location "one.ml" 1; location "two.ml" 2]) in
    if received then Code_results.apply_lsp_answer state query answer;
    state.code_lsp_note <- Some "retained observation";
    Code_results.retire_lsp_input state;
    Alcotest.(check bool) "input removes both admission and recovery intent" true
      (Option.is_none (Fetched.current_key state.code_lsp_query)
       && Option.is_none state.code_location_offer);
    Alcotest.(check bool) "cancelled question is not dispatched by recovery" true
      (Option.is_none (resume_question_after_workspace_confirmation state));
    Code_results.apply_lsp_answer state query answer;
    Alcotest.(check bool) "old answer cannot reopen choices after reconfirmation" true
      (Code_results.take_ready_lsp_locations state ~input_pending:false = Code_results.No_followup
       && not state.palette_open && Option.is_none state.code_navigation
       && state.code_jump_back=[] && state.code_file_cursor=2 && state.code_file_scroll=2
       && state.code_lsp_note=Some "retained observation"))
    [false; true]

let test_location_picker_keeps_ticket_until_close_without_resuming () =
  let state, _ = finder_fixture () in
  close_code_finder state;
  let query, offer = offered_locations state [location "one.ml" 1; location "two.ml" 2] in
  ignore (Code_results.take_ready_lsp_locations state ~input_pending:false);
  state.palette_query <- "two";
  Code_results.retire_lsp_input state;
  Alcotest.(check bool) "picker input retains the actual offer and query ticket" true
    (code_location_offer_current state offer && state.palette_query="two"
     && Option.equal (Fetched.same_request ~equal:code_lsp_query_equal)
          (Some query) (Fetched.current_request state.code_lsp_query));
  close_code_finder state;
  Alcotest.(check bool) "closing choices retires recovery as well as the offer" true
    (Option.is_none (Fetched.current_key state.code_lsp_query)
     && Option.is_none state.code_location_offer);
  Alcotest.(check bool) "closed choices cannot be reissued by recovery" true
    (Option.is_none (resume_question_after_workspace_confirmation state));
  Code_results.apply_lsp_answer state query
    (Ok (Decode.Lsp_locations [location "one.ml" 1; location "two.ml" 2]));
  Alcotest.(check bool) "Esc remains effective after workspace reconfirmation" true
    (Code_results.take_ready_lsp_locations state ~input_pending:false = Code_results.No_followup
     && not state.palette_open && state.code_jump_back=[] && Option.is_none state.code_navigation)

let test_uncancelled_question_resumes_with_file_refresh () =
  let state, _ = finder_fixture () in
  close_code_finder state;
  let old = match Code_results.start_lsp_question ~line:2 state ~question:"references" ~symbol:"target" with
    | Some query -> query | None -> Alcotest.fail "question did not start" in
  close_code_finder state;
  let resumed = match resume_question_after_workspace_confirmation state with
    | Some query -> query | None -> Alcotest.fail "uncancelled question lost recovery intent" in
  let key = Fetched.request_key resumed in
  Alcotest.(check bool) "normal Refresh reissues the question against the current owner" true
    (key.clq_question="references" && key.clq_symbol="target" && key.clq_line=2
     && key.clq_reading == state.workspace_read_authority
     && state.code_file_cursor=2 && state.code_file_scroll=2);
  let answer = Ok (Decode.Lsp_locations [location "one.ml" 1; location "two.ml" 2]) in
  Code_results.apply_lsp_answer state old answer;
  Alcotest.(check bool) "pre-recovery response has no offer ownership" true
    (Option.is_none state.code_location_offer);
  Code_results.apply_lsp_answer state resumed answer;
  Alcotest.(check bool) "fresh resumed answer still opens choices" true
    (Code_results.take_ready_lsp_locations state ~input_pending:false = Code_results.Choose_location
     && not (Code_results.take_ready_found_file state ~input_pending:false))

let test_location_picker_survives_finder_idle_and_late_replies () =
  List.iter (fun late_result ->
    let state, origin = finder_fixture () in
    let catalog, catalog_request = start_read ~equal:code_scope_path_equal
        state.code_catalog (origin.cfo_scope, origin.cfo_dir) in
    state.code_catalog <- catalog;
    let finder_request = finder_select state "lib/new.ml" in
    close_code_finder state;
    let source = state.code_file and history = state.code_jump_back in
    let _, offer = offered_locations state [location "one.ml" 1; location "two.ml" 2] in
    Alcotest.(check bool) "idle opens the multiple-location offer" true
      (Code_results.take_ready_lsp_locations state ~input_pending:false = Code_results.Choose_location);
    (* The main loop consumes these three sources in this order, even when
       the first source has just opened a location picker. *)
    Alcotest.(check bool) "finder idle refuses the newly opened location picker" false
      (Code_results.take_ready_found_file state ~input_pending:false);
    Alcotest.(check bool) "navigation idle has no destination to commit" false
      (Code_results.take_ready_navigation_file state ~input_pending:false);
    state.palette_query <- "two";
    let current_catalog = state.code_catalog and current_finder = state.code_finder_file in
    Code_results.apply_catalog state catalog_request
      (Result.map (fun _ -> {Decode.wfc_root=""; wfc_files=["lib/new.ml"]}) late_result);
    Alcotest.(check bool) "late finder success or failure cannot navigate from locations" false
      (Code_results.apply_found_file state finder_request late_result);
    Alcotest.(check bool) "late finder callbacks cannot publish into location selection" true
      (state.code_catalog == current_catalog && state.code_finder_file == current_finder);
    Alcotest.(check bool) "callbacks retain the offer, its filter and the source reading" true
      (state.palette_open && state.palette_query="two"
       && code_location_offer_current state offer
       && (match state.palette_mode with
           | Palette_locations current -> current == offer
           | Palette_files _ | Palette_jump | Palette_choice _ -> false)
       && state.code_file == source && state.code_jump_back == history
       && state.code_file_cursor=2 && state.code_file_scroll=2
       && state.code_dir="src" && Option.is_none state.code_navigation);
    Alcotest.(check bool) "later idle keeps selection pending without automatic navigation" true
      (Code_results.take_ready_lsp_locations state ~input_pending:false = Code_results.No_followup
       && not (Code_results.take_ready_found_file state ~input_pending:false)))
    [Ok "late finder bytes"; Error "late finder failure"]

let test_multiple_locations_choose_the_filtered_destination () =
  let state, _ = finder_fixture () in
  close_code_finder state;
  state.code_file_hscroll <- 4;
  let current = state.code_file in
  let target = location "lib/한글 two.ml" 2 in
  let _, offer = offered_locations state [location "lib/first.ml" 7; target] in
  Alcotest.(check bool) "answer stages without choosing a destination or creating history" true
    (not state.palette_open && state.code_file == current
     && state.code_jump_back = [] && Option.is_none state.code_navigation);
  Alcotest.(check bool) "queued input defers the selection modal" true
    (Code_results.take_ready_lsp_locations state ~input_pending:true = Code_results.No_followup
     && not state.palette_open);
  Alcotest.(check bool) "idle presents the owned choices" true
    (Code_results.take_ready_lsp_locations state ~input_pending:false = Code_results.Choose_location);
  Code_results.retire_lsp_input state;
  state.palette_query <- "한글 two.ml";
  let chosen_offer, chosen = match Masc_tui_palette.selected_location state with
    | Some selection -> selection | None -> Alcotest.fail "filtered location missing" in
  Alcotest.(check bool) "filtering keeps the original offer and exact destination object" true
    (chosen_offer == offer && chosen == target);
  let owner, request = match Code_results.choose_lsp_location state chosen_offer chosen with
    | Code_results.Read_location_file (owner, request) -> owner, request
    | Code_results.No_followup | Code_results.Reveal_cursor | Code_results.Choose_location ->
        Alcotest.fail "chosen destination did not request a read" in
  check_string "request uses the literal path with Korean and spaces" target.ll_path
    (Fetched.request_key request);
  Alcotest.(check bool) "selection keeps source and history until successful read" true
    (state.code_file == current && state.code_jump_back = [] && not state.palette_open);
  Code_results.apply_file ~intent:(Navigate_code_file owner) state request (Ok "first\nsecond\nthird");
  Alcotest.(check bool) "destination commits through the existing input-priority boundary" true
    (Code_results.take_ready_navigation_file state ~input_pending:false);
  Alcotest.(check bool) "destination directory and selected line commit together" true
    (state.code_dir = "lib" && state.code_file_cursor = 1
     && Fetched.current_key state.code_file = Some target.ll_path);
  (match state.code_jump_back with
   | [source] ->
       Alcotest.(check bool) "B retains the source reading and pan" true
         (source.cj_file=Some "src/old.ml" && source.cj_cursor=2
          && source.cj_scroll=2 && source.cj_hscroll=4)
   | [] | _ :: _ -> Alcotest.fail "successful choice lost its source history")

let test_single_location_yields_before_moving_the_reading () =
  let state, _ = finder_fixture () in
  close_code_finder state;
  state.code_file_hscroll <- 4;
  ignore (offered_locations state [location "src/old.ml" 1]);
  Alcotest.(check bool) "a same-file answer has not moved the reading" true
    (state.code_file_cursor=2 && state.code_file_scroll=2
     && state.code_file_hscroll=4 && state.code_jump_back=[]);
  Alcotest.(check bool) "pending paste or partial input keeps the single answer staged" true
    (Code_results.take_ready_lsp_locations state ~input_pending:true = Code_results.No_followup
     && state.code_file_cursor=2);
  Alcotest.(check bool) "idle follows a single answer without opening a picker" true
    (Code_results.take_ready_lsp_locations state ~input_pending:false = Code_results.Reveal_cursor
     && not state.palette_open && state.code_file_cursor=0 && state.code_file_hscroll=0);
  let history = state.code_jump_back in
  Alcotest.(check bool) "the ready answer is consumed once" true
    (Code_results.take_ready_lsp_locations state ~input_pending:false = Code_results.No_followup
     && state.code_jump_back == history)

let test_location_answers_yield_to_later_input () =
  List.iter (fun locations ->
    List.iter (fun received ->
      let state, _ = finder_fixture () in
      close_code_finder state;
      let current = state.code_file in
      let query = match Code_results.start_lsp_question state ~question:"references" ~symbol:"target" with
        | Some request -> request | None -> Alcotest.fail "question did not start" in
      if received then Code_results.apply_lsp_answer state query (Ok (Decode.Lsp_locations locations));
      ignore (Code_results.take_ready_lsp_locations state ~input_pending:true);
      Code_results.retire_lsp_input state;
      state.code_file_cursor <- 1;
      state.palette_open <- true;
      state.palette_mode <- Palette_jump;
      state.palette_query <- "unfinished unrelated command";
      if not received then Code_results.apply_lsp_answer state query (Ok (Decode.Lsp_locations locations));
      Alcotest.(check bool) "later input owns its source and draft before or after reply receipt" true
        (Code_results.take_ready_lsp_locations state ~input_pending:false = Code_results.No_followup
         && state.code_file == current && state.code_file_cursor=1
         && state.code_jump_back=[] && Option.is_none state.code_navigation
         && Option.is_none state.code_location_offer && state.palette_open
         && state.palette_mode=Palette_jump
         && state.palette_query="unfinished unrelated command"))
      [false; true])
    [[location "src/old.ml" 1]; [location "one.ml" 1; location "two.ml" 2]]

let test_location_offers_do_not_borrow_other_owners () =
  let changes =
    [ (fun state -> state.workspace_authority <-
         (let Workspace_authority generation = state.workspace_authority in
          Workspace_authority (generation + 1)))
    ; (fun state -> state.workspace_read_authority <- ref ())
    ; (fun state -> state.server_identity <- None)
    ; (fun state -> state.code_dir <- "other-directory")
    ; (fun state -> state.view <- Repositories)
    ; (fun state -> set_code_scope state Code_scope_project)
    ; (fun state ->
        let next, request = start_read ~equal:String.equal state.code_file "src/old.ml" in
        state.code_file <- next;
        Code_results.apply_file state request (Ok "same-path replacement"))
    ; suspend_workspace_readings
    ] in
  List.iter (fun change ->
    List.iter (fun received ->
      let state, _ = finder_fixture () in
      close_code_finder state;
      let query = match Code_results.start_lsp_question state ~question:"definition" ~symbol:"target" with
        | Some request -> request | None -> Alcotest.fail "question did not start" in
      let locations = [location "one.ml" 1; location "two.ml" 2] in
      if received then Code_results.apply_lsp_answer state query (Ok (Decode.Lsp_locations locations));
      change state;
      if not received then Code_results.apply_lsp_answer state query (Ok (Decode.Lsp_locations locations));
      let source = state.code_file in
      Alcotest.(check bool) "changed source, view or authority cannot present a late selection" true
        (Code_results.take_ready_lsp_locations state ~input_pending:false = Code_results.No_followup
         && not state.palette_open && state.code_file == source
         && state.code_jump_back=[] && Option.is_none state.code_navigation))
      [false; true]) changes

let test_cancelled_and_invented_location_selections_are_refused () =
  let state, _ = finder_fixture () in
  close_code_finder state;
  let selected = location "lib/selected.ml" 3 in
  let _, offer = offered_locations state [location "lib/other.ml" 1; selected] in
  ignore (Code_results.take_ready_lsp_locations state ~input_pending:false);
  let source = state.code_file in
  let invented = {selected with ll_line=selected.ll_line+1} in
  Alcotest.(check bool) "a location not in the returned list cannot start a read" true
    (Code_results.choose_lsp_location state offer invented = Code_results.No_followup
     && Option.is_none state.code_navigation && state.code_file == source);
  let copied_offer = {offer with clo_locations=[selected]} in
  Alcotest.(check bool) "structural source similarity does not grant offer ownership" true
    (Code_results.choose_lsp_location state copied_offer selected = Code_results.No_followup);
  close_code_finder state;
  Alcotest.(check bool) "Escape retires selection ownership" true
    (Code_results.choose_lsp_location state offer selected = Code_results.No_followup
     && state.code_file == source && state.code_jump_back=[]);
  let _, replacement = offered_locations state [location "lib/new.ml" 1; selected] in
  ignore (Code_results.take_ready_lsp_locations state ~input_pending:false);
  Alcotest.(check bool) "an older same-path offer cannot borrow the replacement picker" true
    (replacement != offer
     && Code_results.choose_lsp_location state offer selected = Code_results.No_followup
     && code_location_offer_current state replacement)

let test_outside_location_is_an_address_without_a_workspace_read () =
  let state, _ = finder_fixture () in
  close_code_finder state;
  let outside : Decode.lsp_location = {ll_path="/external/package.py"; ll_line=8; ll_inside=false} in
  let _, offer = offered_locations state [location "src/old.ml" 1; outside] in
  ignore (Code_results.take_ready_lsp_locations state ~input_pending:false);
  let source = state.code_file in
  Alcotest.(check bool) "an outside selection reports its address without loading or history" true
    (Code_results.choose_lsp_location state offer outside = Code_results.No_followup
     && state.code_file == source && state.code_jump_back=[]
     && Option.is_none state.code_navigation && Option.is_some state.code_lsp_note
     && not state.palette_open)

let () =
  Alcotest.run
    "masc-tui-workspace-entries"
    [ ( "location choices"
      , [ Alcotest.test_case "pending status follows accepted request lifetime" `Quick
            test_lsp_pending_status_follows_request_lifetime
        ; Alcotest.test_case "pending status includes same-question refresh and retry" `Quick
            test_lsp_pending_status_includes_refresh_and_retry
        ; Alcotest.test_case "pending status belongs to the current source" `Quick
            test_lsp_pending_status_belongs_to_the_current_source
        ; Alcotest.test_case "cancelled questions do not resume after workspace recovery" `Quick
            test_cancelled_questions_do_not_resume_after_workspace_recovery
        ; Alcotest.test_case "picker keeps its query ticket only until close" `Quick
            test_location_picker_keeps_ticket_until_close_without_resuming
        ; Alcotest.test_case "uncancelled question resumes with normal Refresh" `Quick
            test_uncancelled_question_resumes_with_file_refresh
        ; Alcotest.test_case "location picker survives finder idle and late callbacks" `Quick
            test_location_picker_survives_finder_idle_and_late_replies
        ; Alcotest.test_case "filter chooses a non-first location and retains B history" `Quick
            test_multiple_locations_choose_the_filtered_destination
        ; Alcotest.test_case "single same-file answer waits for queued input" `Quick
            test_single_location_yields_before_moving_the_reading
        ; Alcotest.test_case "later input wins before and after reply receipt" `Quick
            test_location_answers_yield_to_later_input
        ; Alcotest.test_case "source and authority ownership before and after reply" `Quick
            test_location_offers_do_not_borrow_other_owners
        ; Alcotest.test_case "cancelled and invented selections cannot borrow an offer" `Quick
            test_cancelled_and_invented_location_selections_are_refused
        ; Alcotest.test_case "outside locations never start a workspace file read" `Quick
            test_outside_location_is_an_address_without_a_workspace_read
        ] )
    ; ( "owned locations"
      , [ Alcotest.test_case "ordinary callbacks cannot reset a location" `Quick
            test_locations_retire_ordinary_source_callbacks
        ; Alcotest.test_case "history and destination commit only on success" `Quick
            test_location_commits_history_only_on_success
        ; Alcotest.test_case "failure cancellation and same-path retry preserve source" `Quick
            test_location_failure_cancel_and_replacement_preserve_source
        ; Alcotest.test_case "B replaces an unrelated pending location" `Quick
            test_return_replaces_pending_location_without_consuming_history
        ; Alcotest.test_case "locations cannot borrow changed authority" `Quick
            test_location_cannot_borrow_changed_authority
        ] )
    ; ( "reading return"
      , [ Alcotest.test_case "owned success restores every reading position" `Quick
            test_return_restores_reading_after_success
        ; Alcotest.test_case "navigation activity preserves settled observations" `Quick
            test_navigation_activity_preserves_settled_observations
        ; Alcotest.test_case "navigation activity belongs to its original source" `Quick
            test_navigation_activity_belongs_to_the_original_source
        ; Alcotest.test_case "failure retry and cancellation preserve history" `Quick
            test_return_failure_retry_and_cancel
        ; Alcotest.test_case "return owners cannot be borrowed" `Quick
            test_return_owners_cannot_be_borrowed
        ; Alcotest.test_case "changed content clamps and current file needs no read" `Quick
            test_return_clamps_changed_content_and_restores_current_file
        ; Alcotest.test_case "tree return needs no file" `Quick test_return_to_tree_needs_no_file
        ; Alcotest.test_case "same-file return retires pending ordinary open" `Quick
            test_same_file_return_retires_an_ordinary_open_refresh
        ; Alcotest.test_case "pending return retires ordinary initial and stale reads" `Quick
            test_pending_return_retires_other_ordinary_file_reads
        ] )
    ; ( "file finder"
      , [ Alcotest.test_case "commits navigation only after successful file read" `Quick
            test_finder_commits_navigation_only_after_success
        ; Alcotest.test_case "failure and cancellation retain original reading" `Quick
            test_finder_failure_and_cancel_preserve_original
        ; Alcotest.test_case "scope, authority, source and view retain ownership" `Quick
            test_finder_does_not_borrow_changed_owners
        ; Alcotest.test_case "catalog decoder keeps identity and refuses malformed data" `Quick
            test_catalog_decoder_keeps_identity_and_rejects_missing_data
        ; Alcotest.test_case "received success yields to queued input" `Quick
            test_finder_success_yields_to_pending_input
        ; Alcotest.test_case "ready content cannot borrow reconfirmed read authority" `Quick
            test_finder_ready_content_cannot_borrow_reconfirmed_authority
        ] )
    ; ( "count label"
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
