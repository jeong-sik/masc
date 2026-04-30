(** test_keeper_classifier_helper — coverage for the structured actionable
    signal classifier used by the required-tool contract gate. *)

open Masc_mcp
module C = Keeper_contract_classifier

let s = Alcotest.testable
  (fun fmt v -> Format.pp_print_string fmt (C.actionable_signal_label v))
  (=)

let obs ?(tasks = 0) ?(board = 0) ?(discovered = false) () =
  {
    C.unclaimed_task_count = tasks;
    board_activity_count = board;
    has_discovered_work_section = discovered;
  }

let test_no_signal_when_empty () =
  Alcotest.check s "empty observation"
    C.No_actionable_signal
    (C.classify_actionable_signal (obs ()))

let test_unclaimed_tasks_take_top_priority () =
  Alcotest.check s "tasks > board"
    C.Has_unclaimed_tasks
    (C.classify_actionable_signal (obs ~tasks:1 ~board:5 ()));
  Alcotest.check s "tasks > discovered"
    C.Has_unclaimed_tasks
    (C.classify_actionable_signal (obs ~tasks:1 ~discovered:true ()));
  Alcotest.check s "tasks > all"
    C.Has_unclaimed_tasks
    (C.classify_actionable_signal
       (obs ~tasks:1 ~board:5 ~discovered:true ()))

let test_board_takes_second_priority () =
  Alcotest.check s "board > discovered when no tasks"
    C.Has_board_activity
    (C.classify_actionable_signal (obs ~board:1 ~discovered:true ()))

let test_discovered_only_when_no_other () =
  Alcotest.check s "discovered alone"
    C.Has_discovered_work
    (C.classify_actionable_signal (obs ~discovered:true ()))

let test_allowed_tools_preserve_fallback_precedence () =
  Alcotest.check s "board wins when claim tools are hidden"
    C.Has_board_activity
    (C.classify_actionable_signal_with_allowed_tools
       ~allowed_tool_names:[ "keeper_board_post" ]
       (obs ~tasks:2 ~board:1 ()));
  Alcotest.check s "discovered wins when claim and board tools are hidden"
    C.Has_discovered_work
    (C.classify_actionable_signal_with_allowed_tools
       ~allowed_tool_names:[ "keeper_tasks_audit" ]
       (obs ~tasks:2 ~board:1 ~discovered:true ()));
  Alcotest.check s "no unwinnable signal without action tools"
    C.No_actionable_signal
    (C.classify_actionable_signal_with_allowed_tools
       ~allowed_tool_names:[ "keeper_tasks_list"; "masc_status" ]
       (obs ~tasks:2 ~board:1 ~discovered:true ()))

let test_allowed_tools_keep_top_priority_when_actionable () =
  Alcotest.check s "unclaimed wins with claim tool visible"
    C.Has_unclaimed_tasks
    (C.classify_actionable_signal_with_allowed_tools
       ~allowed_tool_names:[ "keeper_task_claim"; "keeper_board_post" ]
       (obs ~tasks:2 ~board:1 ~discovered:true ()));
  Alcotest.check s "board wins over discovered with board tool visible"
    C.Has_board_activity
    (C.classify_actionable_signal_with_allowed_tools
       ~allowed_tool_names:[ "keeper_board_comment"; "keeper_tasks_audit" ]
       (obs ~board:1 ~discovered:true ()))

let test_zero_counts_are_inactive () =
  (* count = 0 must NOT promote to *_activity (boundary check on ">0"). *)
  Alcotest.check s "tasks=0, board=0, no_discovery"
    C.No_actionable_signal
    (C.classify_actionable_signal (obs ~tasks:0 ~board:0 ()))

let test_negative_counts_are_inactive () =
  (* defensive: if a buggy upstream sends a negative count, it must
     not be treated as positive. *)
  Alcotest.check s "negative tasks behave as zero"
    C.No_actionable_signal
    (C.classify_actionable_signal (obs ~tasks:(-1) ~board:(-3) ()))

let test_is_actionable_boolean_consistency () =
  let cases =
    [
      (C.No_actionable_signal, false);
      (C.Has_unclaimed_tasks, true);
      (C.Has_board_activity, true);
      (C.Has_discovered_work, true);
    ]
  in
  List.iter
    (fun (sig_, expected) ->
      Alcotest.(check bool) (C.actionable_signal_label sig_) expected
        (C.is_actionable sig_))
    cases

let test_is_actionable_matches_classify () =
  (* Boolean equivalence: classify(...) <> No_actionable_signal
     iff is_actionable (classify ...) = true. *)
  let observations =
    [
      obs ();
      obs ~tasks:5 ();
      obs ~board:3 ();
      obs ~discovered:true ();
      obs ~tasks:2 ~board:1 ~discovered:true ();
    ]
  in
  List.iter
    (fun o ->
      let sig_ = C.classify_actionable_signal o in
      let expected = sig_ <> C.No_actionable_signal in
      Alcotest.(check bool)
        (Printf.sprintf "is_actionable(%s) = (signal <> No_actionable_signal)"
           (C.actionable_signal_label sig_))
        expected (C.is_actionable sig_))
    observations

let () =
  Alcotest.run "keeper_classifier_helper"
    [
      ( "classify_actionable_signal",
        [
          Alcotest.test_case "empty observation -> none" `Quick
            test_no_signal_when_empty;
          Alcotest.test_case "unclaimed_tasks beats all" `Quick
            test_unclaimed_tasks_take_top_priority;
          Alcotest.test_case "board beats discovered" `Quick
            test_board_takes_second_priority;
          Alcotest.test_case "discovered alone" `Quick
            test_discovered_only_when_no_other;
          Alcotest.test_case "allowed tools preserve fallback precedence" `Quick
            test_allowed_tools_preserve_fallback_precedence;
          Alcotest.test_case "allowed tools keep top actionable priority" `Quick
            test_allowed_tools_keep_top_priority_when_actionable;
          Alcotest.test_case "zero counts are inactive" `Quick
            test_zero_counts_are_inactive;
          Alcotest.test_case "negative counts are inactive" `Quick
            test_negative_counts_are_inactive;
        ] );
      ( "is_actionable",
        [
          Alcotest.test_case "boolean per variant" `Quick
            test_is_actionable_boolean_consistency;
          Alcotest.test_case "matches classify result" `Quick
            test_is_actionable_matches_classify;
        ] );
    ]
