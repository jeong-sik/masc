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
  Alcotest.(check bool) "a phase counter" true (contains "● Exec: 1" row);
  Alcotest.(check bool) "no sentence for the count" false (contains "no goals" row)

let () =
  Alcotest.run "tui_planning_summary_rows"
    [ ( "planning summary rows"
      , [ Alcotest.test_case "no goals is the count alone" `Quick
            test_no_goals_is_the_count_alone
        ; Alcotest.test_case "goals keep the share and the phases" `Quick
            test_goals_keep_the_share_and_the_phases
        ] )
    ]
