(* The Approvals surface is where an operator authorises a command, and the
   half of it that matters cannot be reached by a unit test: [render_approvals]
   lives in the executable, so nothing links it (task-550). Three facts about
   it were wrong at the same time, and each one typechecks either way. This is
   the half the compiler does not hold.

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

let () =
  Alcotest.run "masc_tui_approval_row_wiring"
    [ ( "approvals"
      , [ Alcotest.test_case "the detail pane says where the command would run"
            `Quick test_the_detail_pane_says_where_the_command_would_run
        ; Alcotest.test_case "the title does not count another queue" `Quick
            test_the_title_does_not_count_another_queue
        ; Alcotest.test_case "the operation is compared before repeating"
            `Quick
            test_the_detail_pane_compares_before_repeating_the_operation
        ] )
    ]
