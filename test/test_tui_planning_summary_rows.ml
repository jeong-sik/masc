(* The goal rollup above the Planning list. With no goals it said the count,
   a sentence saying the count, and five zero counters. *)

let plain = Masc_tui_theme.strip_sgr

let contains needle haystack =
  let n = String.length needle and h = String.length haystack in
  let rec scan i = i + n <= h && (String.sub haystack i n = needle || scan (i + 1)) in
  n = 0 || scan 0

let rollup ~active ~done_ : Masc_tui_types.planning_rollup =
  { pr_active = active
  ; pr_verifying = 0
  ; pr_awaiting_confirmation = 0
  ; pr_done = done_
  ; pr_dropped = 0
  }

let test_no_goals_is_the_count_alone () =
  Alcotest.(check string) "the count, no sentence and no zero counters"
    "  Goals: 0"
    (plain (Masc_tui_render_prim.planning_rollup_row ~cols:120 (rollup ~active:0 ~done_:0)))

let test_goals_keep_the_share_and_the_phases () =
  let row = plain (Masc_tui_render_prim.planning_rollup_row ~cols:120 (rollup ~active:1 ~done_:1)) in
  Alcotest.(check bool) "the share" true (contains "(1/2)" row);
  Alcotest.(check bool) "a phase counter" true (contains "Exec: 1" row);
  Alcotest.(check bool) "no sentence for the count" false (contains "no goals" row)

(* A phase with no goal in it is not counted: the list under the row names
   every goal's phase, and five counters with single digits are 92 cells,
   which beside the roster pane cut the Dropped count off the row. *)
let test_an_empty_phase_is_not_counted () =
  let row = plain (Masc_tui_render_prim.planning_rollup_row ~cols:120 (rollup ~active:1 ~done_:1)) in
  List.iter
    (fun empty ->
      Alcotest.(check bool) (empty ^ " is not on the row") false (contains empty row))
    [ "Ver: 0"; "Conf: 0"; "Drop: 0" ];
  Alcotest.(check bool) "the phases with goals stay" true
    (contains "Exec: 1" row && contains "Done: 1" row)

(* The Goal counters sat over the Backlog row in their own marks: a filled
   circle for Executing over a row where the filled circle is done. A stage
   both rows have now wears one mark in both. *)
let test_one_mark_means_one_stage_across_the_two_rows () =
  let open Masc_tui_theme.Glyph in
  let goals =
    plain
      (Masc_tui_render_prim.planning_rollup_row ~cols:120
         { pr_active = 1
         ; pr_verifying = 1
         ; pr_awaiting_confirmation = 1
         ; pr_done = 1
         ; pr_dropped = 1
         })
  in
  let backlog =
    Masc_tui_render_prim.planning_backlog_counts
      { pb_todo = 1; pb_claimed = 1; pb_running = 1; pb_done = 1; pb_cancelled = 1 }
  in
  let backlog_label key =
    match List.find_opt (fun (k, _, _) -> String.equal k key) backlog with
    | Some (_, _, label) -> label
    | None -> Alcotest.failf "no Backlog count %s" key
  in
  List.iter
    (fun (goal_counter, backlog_key, mark) ->
      Alcotest.(check bool)
        (goal_counter ^ " wears the mark") true
        (contains (mark ^ " " ^ goal_counter) goals);
      Alcotest.(check string)
        (backlog_key ^ " wears the same mark")
        (mark ^ " " ^ backlog_key) (backlog_label backlog_key))
    [ ("Exec", "running", progress_active)
    ; ("Done", "done", progress_done)
    ; ("Drop", "cancelled", progress_ended)
    ];
  Alcotest.(check string) "claimed wears the mark its Task rows wear"
    (progress_active ^ " claimed") (backlog_label "claimed");
  Alcotest.(check string) "todo waits"
    (progress_waiting ^ " todo") (backlog_label "todo")

let () =
  Alcotest.run "tui_planning_summary_rows"
    [ ( "planning summary rows"
      , [ Alcotest.test_case "no goals is the count alone" `Quick
            test_no_goals_is_the_count_alone
        ; Alcotest.test_case "goals keep the share and the phases" `Quick
            test_goals_keep_the_share_and_the_phases
        ; Alcotest.test_case "an empty phase is not counted" `Quick
            test_an_empty_phase_is_not_counted
        ; Alcotest.test_case "one mark means one stage across the two rows" `Quick
            test_one_mark_means_one_stage_across_the_two_rows
        ] )
    ]
