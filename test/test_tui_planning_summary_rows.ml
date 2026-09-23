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
      { pb_todo = 1
      ; pb_claimed = 1
      ; pb_running = 1
      ; pb_awaiting_verification = 1
      ; pb_done = 1
      ; pb_cancelled = 1
      }
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
    [ ("Exec", "in_progress", progress_active)
    ; ("Done", "done", progress_done)
    ; ("Drop", "cancelled", progress_ended)
    ];
  Alcotest.(check string) "claimed wears the mark its Task rows wear"
    (progress_active ^ " claimed") (backlog_label "claimed");
  Alcotest.(check string) "todo waits"
    (progress_waiting ^ " todo") (backlog_label "todo")

(* The retained-history row named two counts, and the goals that reached an
   end are a subset of the goals no longer listed -- so with every one of them
   ended it printed the same number twice. *)
let test_all_ended_says_the_count_once () =
  Alcotest.(check string) "one count, no second number"
    "  No longer listed: 3"
    (Masc_tui_render_prim.planning_goal_history_summary ~unlisted:3 ~ended:3)

(* The server fills closed_at only for a goal whose last phase is terminal, so
   the difference counts goals that left the list with nothing recorded. That
   was the one reading the row made an operator subtract. *)
let test_the_row_names_the_goals_with_no_outcome () =
  let row = Masc_tui_render_prim.planning_goal_history_summary ~unlisted:5 ~ended:3 in
  Alcotest.(check bool) "the unlisted count" true (contains "No longer listed: 5" row);
  Alcotest.(check bool) "the difference, named" true (contains "2 with no outcome" row);
  Alcotest.(check bool) "not the subset count" false (contains "3" row)

(* One state, one word. This count decodes the wire's [in_progress] field and
   a Task row draws [Masc_domain.task_status_to_string] beside the same mark,
   so a Backlog label that renamed it left one state reading as two on one
   screen -- "running" here, "in_progress" on the row and in the CLI tally. *)
let test_the_backlog_spells_a_state_as_a_task_row_does () =
  let backlog =
    Masc_tui_render_prim.planning_backlog_counts
      { pb_todo = 0
      ; pb_claimed = 1
      ; pb_running = 1
      ; pb_awaiting_verification = 1
      ; pb_done = 0
      ; pb_cancelled = 0
      }
  in
  let label key =
    match List.find_opt (fun (k, _, _) -> String.equal k key) backlog with
    | Some (_, _, label) -> label
    | None -> Alcotest.failf "no Backlog count %s" key
  in
  List.iter
    (fun (key, status) ->
       Alcotest.(check string)
         (key ^ " is spelled as a Task row spells it")
         (Masc_tui_theme.Glyph.progress_active ^ " "
          ^ Masc_domain.task_status_to_string status)
         (label key))
    [ ("claimed", Masc_domain.Claimed { assignee = "a"; claimed_at = "t" })
    ; ("in_progress", Masc_domain.InProgress { assignee = "a"; started_at = "t" })
    ; ( "awaiting_verification"
      , Masc_domain.AwaitingVerification
          { assignee = "a"
          ; started_at = "t"
          ; submitted_at = "t"
          ; intent = Masc_domain.Complete_task
          ; verification_id = "v-1"
          } )
    ]

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
        ; Alcotest.test_case "the backlog spells a state as a task row does" `Quick
            test_the_backlog_spells_a_state_as_a_task_row_does
        ; Alcotest.test_case "all ended says the count once" `Quick
            test_all_ended_says_the_count_once
        ; Alcotest.test_case "the row names the goals with no outcome" `Quick
            test_the_row_names_the_goals_with_no_outcome
        ] )
    ]
