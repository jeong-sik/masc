open Masc_tui_types

let slot slsc_slot_id slsc_count : Masc.Tui_decode.standalone_lane_slot_count =
  { slsc_slot_id; slsc_count }

let unnamed ~succeeded ~failed ~cancelled slots =
  standalone_lane_runs_naming_no_slot ~succeeded ~failed ~cancelled slots

(* The live Board Attention lane, 2026-09-23: 482 succeeded, 6 failed, 0
   cancelled, and a slot history adding to 357. The 132 that named nothing
   were in none of the per-slot counts, and the run total sits one line above
   them. *)
let test_the_live_board_lane_names_its_shortfall () =
  Alcotest.(check int) "the runs the history does not account for" 131
    (unnamed ~succeeded:482 ~failed:6 ~cancelled:0
       [ slot "glm-coding.glm-5.3-flash" 290
       ; slot "ollama_cloud.ollama-cloud-deepseek-v4-1-flash" 51
       ; slot "claude_code.claude-sonnet-5" 16
       ])

(* A lane whose every finished run named a slot has nothing to add. *)
let test_a_complete_history_has_no_shortfall () =
  Alcotest.(check int) "nothing is missing" 0
    (unnamed ~succeeded:59 ~failed:0 ~cancelled:0
       [ slot "ollama_cloud.deepseek-v4-pro" 59 ]);
  Alcotest.(check int) "failures and cancellations count as finished" 0
    (unnamed ~succeeded:2 ~failed:13 ~cancelled:1
       [ slot "a" 10; slot "b" 6 ])

(* Running rows are not in any of the three counts, so a lane mid-run does not
   report its running work as unnamed. *)
let test_a_running_lane_does_not_count_its_running_work () =
  Alcotest.(check int) "three running, all finished work named" 0
    (unnamed ~succeeded:10 ~failed:0 ~cancelled:0 [ slot "a" 10 ])

(* The subtraction never reads below zero: a history that somehow counted more
   than the lane finished says nothing rather than a negative. *)
let test_the_reading_never_goes_below_zero () =
  Alcotest.(check int) "more named than finished" 0
    (unnamed ~succeeded:5 ~failed:0 ~cancelled:0 [ slot "a" 9 ])

(* No slots at all is not a shortfall of every run: the detail draws no
   history line then, so there is nothing for this to qualify. *)
let test_an_empty_history_is_the_callers_case_not_this_one () =
  Alcotest.(check int) "the arithmetic still answers" 7
    (unnamed ~succeeded:7 ~failed:0 ~cancelled:0 [])

let () =
  Alcotest.run "masc_tui_lane_slot_reach"
    [ ( "slot history reach"
      , [ Alcotest.test_case "the live Board lane names its shortfall" `Quick
            test_the_live_board_lane_names_its_shortfall
        ; Alcotest.test_case "a complete history has no shortfall" `Quick
            test_a_complete_history_has_no_shortfall
        ; Alcotest.test_case "a running lane does not count its running work"
            `Quick test_a_running_lane_does_not_count_its_running_work
        ; Alcotest.test_case "the reading never goes below zero" `Quick
            test_the_reading_never_goes_below_zero
        ; Alcotest.test_case "an empty history is the caller's case" `Quick
            test_an_empty_history_is_the_callers_case_not_this_one
        ] )
    ]
