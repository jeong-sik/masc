(* Rows the compiler cannot hold. Every binding asserted here lives in the TUI
   executable, so nothing links it (task-550) -- and every fact asserted is one
   that typechecks either way: which field a cell reads, whether a mark carries
   what a colour carries, whether a column measures itself.

   It began with the Approvals surface, where an operator authorises a command
   and three facts about the row were wrong at once. The other surfaces joined
   as the same shapes turned up on them.

   The measurement that found them, at 80, 140 and 200 columns with seven Gate
   rows waiting: the cell opened with the request schema name, then the
   absolute working directory, and ran out of row. It now opens with

     git clone --depth 1 https://github.com/jeong-sik/masc.git repos/masc

   which fits at every one of those widths, because a command is short and an
   envelope is not. *)

let render = "bin/masc_tui_render.ml"

let reads ~binding_name ~fields =
  Ast_grep.count_field_accesses_outside_calls_in_value_binding
    ~module_path:render ~binding_name ~callees:[] ~fields

(* The detail under the list is three rows, and [boxed_surface_chrome_rows]
   budgets one for the selected row's own line. Every kind takes that one
   except a held tool call, which answers two questions -- what is being asked,
   and why it was held -- and the ask runs the width of the pane, so at eighty
   columns they cannot share a row.

   That second row used to be spelled as a literal ["\\n"]: backslash and n,
   printed to the operator as those two characters, because a real newline
   would have drawn a row nobody had counted. Both halves live in one place
   now -- the budget asks [approval_detail_line] how tall its line is before
   spending the rows on it -- and this pins that they stay one place. A height
   declared beside the drawing instead of read off it is how the footer floats
   a row, which is the defect the queue rows already taught the chat pane
   (#29818). *)
let test_the_detail_height_is_read_off_the_line_it_draws () =
  let calls callee =
    Ast_grep.count_calls_in_value_binding ~module_path:render
      ~binding_name:"render_approvals" ~callee
  in
  Alcotest.(check int) "the surface builds the detail line once" 1
    (calls "approval_detail_line");
  Alcotest.(check int) "and asks that same line for its height" 1
    (calls "approval_detail_rows")

(* Where a command runs decides what it means: [git clone] into a container is
   not [git clone] onto the host. The decoder carries both, and the detail
   pane is the only surface with room for them. *)
let test_the_detail_pane_says_where_the_command_would_run () =
  Alcotest.(check bool)
    "the detail pane reads the sandbox it was granted against" true
    (reads ~binding_name:"render_approvals" ~fields:[ "gp_execution_sandbox" ]
     > 0);
  Alcotest.(check bool) "and the directory it would run in" true
    (reads ~binding_name:"render_approvals" ~fields:[ "gp_execution_cwd" ] > 0)

(* The title counted the pending-confirm queue, which is one of the three lists
   this screen draws. With seven Gate rows waiting and that queue empty, the
   title read "(0/0, hidden 0)" while the tab beside it read "7". The hidden
   count stays -- an actor filter really does hide confirm entries -- but the
   pair that looked like the screen's count is gone. *)
let test_the_title_does_not_count_another_queue () =
  Alcotest.(check int)
    "no visible/total pair from the confirm queue in the title" 0
    (reads ~binding_name:"render_approvals"
       ~fields:[ "aps_visible_count"; "aps_total_count" ]);
  Alcotest.(check bool) "the filter note it keeps is still read" true
    (reads ~binding_name:"render_approvals" ~fields:[ "aps_hidden_count" ] > 0)

(* [operation=] is the right-hand side of the line directly above whenever the
   two agree, which is every operation but an identity call. The detail line
   compares them rather than printing it unconditionally, because at eighty
   columns that repetition cost the sandbox its place. *)
let test_the_detail_pane_compares_before_repeating_the_operation () =
  Alcotest.(check bool) "the operation is weighed against what is already shown"
    true
    (reads ~binding_name:"render_approvals"
       ~fields:[ "gp_display_tool"; "gp_operation" ]
     > 1)

(* The subject column took [cols - 76] -- everything the fixed parts did not
   use. On rows whose subject is a keeper name, that spent ninety cells on
   [edgar.a.poe] and left the recurrence past it reading [daily 08:00:00 A~]:
   the timezone, which is the part of a recurrence a reader cannot infer.

   Measured from the rows now, the way the Approvals and Fusion tables measure
   theirs. The rule that builds the subject moved out of the row loop for it,
   so the width and the cell cannot read different strings. *)
(* A wake that fired and a wake that was acted on read the same. [LAST WAKE]
   reports the dispatch and [DELIVERY EVIDENCE] one word of verdict, and the
   reaction ledger folds four separate observations into that word -- so a
   Keeper that took the wake and never started a turn looked like one that
   did.

   The four are on the wire on every row that has evidence at all (5/5 in the
   live workspace, with reaction_kind and the quarantine count beside them).
   This pins that the detail reads them rather than the verdict alone. *)
let test_the_schedule_detail_says_what_became_of_the_wake () =
  let steps =
    [ "sch_wake_seen"
    ; "sch_turn_started"
    ; "sch_queue_ack_seen"
    ; "sch_wake_cancelled"
    ]
  in
  List.iter
    (fun step ->
      Alcotest.(check bool)
        (Printf.sprintf "the turn block reads %s" step)
        true
        (reads ~binding_name:"schedule_turn_rows" ~fields:[ step ] > 0))
    steps;
  Alcotest.(check bool) "and the detail draws that block" true
    (Ast_grep.count_calls_in_value_binding ~module_path:render
       ~binding_name:"schedule_detail_lines" ~callee:"schedule_turn_rows"
     > 0)

let test_the_schedule_subject_is_measured_not_given_the_line () =
  (* Twice: once to measure the column, once to fill the cell. One call would
     mean the width came from somewhere else, which is the state this replaced. *)
  Alcotest.(check int) "one rule builds the subject, and the width reads it" 2
    (Ast_grep.count_calls_in_value_binding ~module_path:render
       ~binding_name:"render_schedule_list" ~callee:"schedule_row_subject");
  Alcotest.(check bool) "the column is measured against the rows" true
    (Ast_grep.count_identifiers_outside_calls_in_value_binding
       ~module_path:render ~binding_name:"render_schedule_list" ~callees:[]
       ~identifiers:[ "subject_width" ]
     > 0)

(* The repository declaration stores a path that may be relative to the
   workspace base.  The server owns that base path; a TUI running from a
   different cwd cannot safely resolve the declaration itself.  Pin both
   halves of the seam: the route publishes the resolved value, and the table
   plus selected-row context read it while Keeper assignment moves out of the
   space-constrained table column. *)
let test_repositories_show_the_server_resolved_checkout_path () =
  let producer = "lib/server/server_routes_http_routes_repositories.ml" in
  Alcotest.(check int) "the route names one resolved path field" 1
    (Ast_grep.count_string_literals_in_value_binding ~module_path:producer
       ~binding_name:"repository_json" ~literals:[ "resolved_local_path" ]);
  Alcotest.(check int) "the route resolves it against the server base" 1
    (Ast_grep.count_calls_in_value_binding ~module_path:producer
       ~binding_name:"repository_json" ~callee:"Repo_store.local_path");
  Alcotest.(check bool) "the repository context reads the resolved path" true
    (reads ~binding_name:"repository_context_lines"
       ~fields:[ "rp_resolved_local_path" ]
     > 0);
  Alcotest.(check bool) "and keeps assignment in the selected-row context" true
    (reads ~binding_name:"repository_context_lines" ~fields:[ "rp_keepers" ] > 0)

let test_memory_surface_keeps_the_starvation_axes () =
  (* Starvation depends on ordinary absence and failed Librarian runs, while a
     source-bound snapshot changes the truthful row label from memoryless to
     source-only. Keep all three axes in the renderer. *)
  List.iter
    (fun field ->
      Alcotest.(check bool) ("memory_row_style reads " ^ field) true
        (reads ~binding_name:"memory_row_style" ~fields:[ field ] > 0))
    [ "mkh_snapshot_present"
    ; "mkh_source_snapshot_present"
    ; "mkh_librarian_failures"
    ];
  Alcotest.(check bool) "the title names the starving count" true
    (reads ~binding_name:"render_memory" ~fields:[ "mhs_starving_keepers" ] > 0);
  Alcotest.(check bool) "the title keeps source facts separate" true
    (reads ~binding_name:"render_memory" ~fields:[ "mhs_total_source_facts" ] > 0);
  List.iter
    (fun field ->
      Alcotest.(check bool) ("memory row reads " ^ field) true
        (reads ~binding_name:"memory_row_line" ~fields:[ field ] > 0))
    [ "mkh_source_revision"
    ; "mkh_source_facts"
    ; "mkh_source_invalidations"
    ; "mkh_source_snapshot_bytes"
    ]

let test_repository_changes_keep_the_git_axes () =
  let producer = "lib/server/server_routes_http_routes_repositories.ml" in
  Alcotest.(check int) "the route reads exact Git status rows" 1
    (Ast_grep.count_calls_in_value_binding ~module_path:producer
       ~binding_name:"handle_list_repository_changes"
       ~callee:"Repo_git.status_files");
  List.iter
    (fun field ->
      Alcotest.(check bool) ("renderer reads " ^ field) true
        (reads ~binding_name:"repository_change_status" ~fields:[ field ] > 0))
    [ "rc_staged"; "rc_unstaged"; "rc_untracked"; "rc_conflicted" ]

let test_project_changes_use_the_requested_workspace_root () =
  let producer = "lib/server/server_routes_http_routes_workspace.ml" in
  Alcotest.(check int) "the project route reads status at the resolved root" 1
    (Ast_grep.count_calls_in_value_binding ~module_path:producer
       ~binding_name:"add_routes" ~callee:"Repo_git.status_files_at")

(* The Lanes summary drew one mark for four states while the style beside it
   was green, red or grey. On a column of identical marks the lane failing 133
   of 1095 runs looked exactly like the four that were fine, and the only two
   channels that separated them were a colour and a word.

   [standalone_lane_row] is in the same unlinkable executable, so the marks are
   asserted here: three distinct ones, matching the three the style makes. *)
let test_a_lane_mark_says_what_its_colour_says () =
  (* Each mark separately, not three occurrences of any of them: folding two
     states back onto one mark leaves the total at three and a count would
     still pass. This failed to catch exactly that before it was written this
     way. *)
  List.iter
    (fun (mark, what) ->
      Alcotest.(check bool)
        (Printf.sprintf "the %s class has its own mark" what)
        true
        (Ast_grep.count_string_literals_in_value_binding ~module_path:render
           ~binding_name:"standalone_lane_row" ~literals:[ mark ]
         > 0))
    [ ("\xe2\x97\x8f", "running or idle")
    ; ("\xe2\x9c\x97", "degraded or unavailable")
    ; ("\xc2\xb7", "nothing retained")
    ]

(* A lane that cannot admit work said so and not why. The cell read "no
   admitted slot", which restates the status word beside it, while the
   projection carried the reason -- and an unconfigured lane and a lane whose
   registry could not be read are different problems.

   [sl_admission_error] is a [required_nullable_string_field]: the server
   sends it on every lane, so a decoder that reads it and a screen that does
   not is the whole of the gap. *)
let test_a_lane_that_cannot_admit_says_why () =
  Alcotest.(check bool) "the row reads the reason the projection carries" true
    (Ast_grep.count_field_accesses_outside_calls_in_value_binding
       ~module_path:render ~binding_name:"standalone_lane_row" ~callees:[]
       ~fields:[ "sl_admission_error" ]
     > 0);
  (* Reading the field is not drawing it: an arm that matches [Some _] and
     then prints the old sentence passes a read count. What the cell must not
     say any more is the sentence that only restated the status word, and it
     is kept for the case that really has no reason to give -- so the arm that
     has one is asserted by the [reason] it binds reaching the cell. *)
  (* Twice: the lane with no admitted slot reads as its reason, and the lane
     that has slots and a reason reads as both. An arm that matched [Some _]
     and printed the old sentence would pass the read count above. *)
  Alcotest.(check int) "the reason is what the cell becomes, on both arms" 2
    (Ast_grep.count_identifiers_outside_calls_in_value_binding
       ~module_path:render ~binding_name:"standalone_lane_row" ~callees:[]
       ~identifiers:[ "reason" ])

(* The fleet summary above the Keepers table read "2 offline" and named
   one keeper among them, while that keeper's own row drew a turning mark and a
   climbing clock. Its turn had started and never been closed; the process
   behind it had gone. A turn state that outlives its process is the row an
   operator most needs to read, and it looked like the healthiest kind.

   The elapsed stays -- a turn open two minutes is the fact. The motion does
   not: it means work is progressing, and for a keeper the health reading calls
   offline or zombie, none is. *)
let test_a_turn_on_a_keeper_that_is_not_running_stops_moving () =
  (* Counted as an identifier: the reading reaches the match through
     [Option.map keeper_health_reading health], so it is passed rather than
     applied and a call count sees nothing. *)
  Alcotest.(check bool) "the row weighs the health reading against the turn"
    true
    (Ast_grep.count_identifiers_outside_calls_in_value_binding
       ~module_path:render ~binding_name:"keeper_row_content" ~callees:[]
       ~identifiers:[ "Tui_decode.keeper_health_reading" ]
     > 0);
  (* Both halves, named: a match that reached only one of them would leave the
     other drawing a live mark on a dead keeper. *)
  List.iter
    (fun reading ->
      Alcotest.(check bool)
        (Printf.sprintf "%s is one of the readings that stops the mark" reading)
        true
        (Ast_grep.count_constructors_in_value_binding ~module_path:render
           ~binding_name:"keeper_row_content" ~constructors:[ reading ]
         > 0))
    [ "Tui_decode.Health_offline"; "Tui_decode.Health_zombie" ]

let () =
  Alcotest.run "masc_tui_row_wiring"
    [ ( "approvals"
      , [ Alcotest.test_case "the detail pane says where the command would run"
            `Quick test_the_detail_pane_says_where_the_command_would_run
        ; Alcotest.test_case "the detail height is read off the line it draws"
            `Quick test_the_detail_height_is_read_off_the_line_it_draws
        ; Alcotest.test_case "the title does not count another queue" `Quick
            test_the_title_does_not_count_another_queue
        ; Alcotest.test_case "the operation is compared before repeating"
            `Quick
            test_the_detail_pane_compares_before_repeating_the_operation
        ; Alcotest.test_case "a lane mark says what its colour says" `Quick
            test_a_lane_mark_says_what_its_colour_says
        ; Alcotest.test_case "the schedule subject is measured" `Quick
            test_the_schedule_subject_is_measured_not_given_the_line
        ; Alcotest.test_case "the schedule detail says what became of the wake"
            `Quick test_the_schedule_detail_says_what_became_of_the_wake
        ; Alcotest.test_case "Repositories show the server-resolved path"
            `Quick test_repositories_show_the_server_resolved_checkout_path
        ; Alcotest.test_case "Repository changes keep the Git axes" `Quick
            test_repository_changes_keep_the_git_axes
        ; Alcotest.test_case "Memory surface keeps the starvation axes" `Quick
            test_memory_surface_keeps_the_starvation_axes
        ; Alcotest.test_case "Project changes use the workspace root" `Quick
            test_project_changes_use_the_requested_workspace_root
        ; Alcotest.test_case "a turn on a keeper that is not running stops"
            `Quick test_a_turn_on_a_keeper_that_is_not_running_stops_moving
        ; Alcotest.test_case "a lane that cannot admit says why" `Quick
            test_a_lane_that_cannot_admit_says_why
        ] )
    ]
