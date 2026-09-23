open Masc_tui_types

let slot slsc_slot_id slsc_count : Masc.Tui_decode.standalone_lane_slot_count =
  { slsc_slot_id; slsc_count }

let lane ?(running = 0) ?(vendor_system_one = 0) ?(server_restarted = 0) ?(no_slot = 0)
    ~succeeded ~failed ~cancelled slots : Masc.Tui_decode.standalone_lane =
  { sl_lane_id = "board_attention_exact"
  ; sl_label = "Board Attention"
  ; sl_purpose = None
  ; sl_required = true
  ; sl_status = Masc.Tui_decode.Standalone_idle
  ; sl_configuration_state = Masc.Tui_decode.Lane_ready
  ; sl_jev = None
  ; sl_admitted_slots = []
  ; sl_cli_slots = []
  ; sl_dropped_slots = []
  ; sl_declared_slots = []
  ; sl_admission_error = None
  ; sl_retained_run_count = succeeded + failed + cancelled + running
  ; sl_running_count = running
  ; sl_succeeded_count = succeeded
  ; sl_failed_count = failed
  ; sl_cancelled_count = cancelled
  ; sl_last_started_at = None
  ; sl_last_terminal_at = None
  ; sl_last_outcome = None
  ; sl_p50_elapsed_s = None
  ; sl_selected_slots = slots
  ; sl_runs_without_slot =
      { slws_vendor_system_one = vendor_system_one
      ; slws_server_restarted = server_restarted
      ; slws_no_slot = no_slot
      }
  }

let parts = standalone_lane_runs_without_slot_parts
let gap = standalone_lane_slot_history_gap

(* The live Board Attention lane, 2026-09-23: of its newest 200 runs, 41
   succeeded without a slot and 6 were closed by a restart. The successes are
   Vendor System One answers, which the run registry records without a slot
   by contract (#37296), so they are named as such rather than as missing. *)
let test_the_board_lane_names_vendor_system_one_and_restarts () =
  let board =
    lane ~vendor_system_one:41 ~server_restarted:6 ~succeeded:150 ~failed:6
      ~cancelled:0
      [ slot "glm-coding.glm-5.3-flash" 100; slot "claude_code.claude-sonnet-5" 9 ]
  in
  Alcotest.(check int) "the counts cover every finished run" 0 (gap board);
  Alcotest.(check (list string)) "each reason is its own count"
    [ "Vendor System One: 41"; "closed by server restart: 6" ]
    (parts board)

(* A lane whose every finished run named a slot has nothing to add. *)
let test_a_complete_history_adds_nothing () =
  let verifier =
    lane ~succeeded:2 ~failed:13 ~cancelled:1 [ slot "a" 10; slot "b" 6 ]
  in
  Alcotest.(check int) "failures and cancellations count as finished" 0 (gap verifier);
  Alcotest.(check (list string)) "nothing is drawn" [] (parts verifier)

(* A run that finished before any slot was bound, for no reason the server
   names, is still counted, under its own words. *)
let test_a_run_with_no_named_reason_is_counted () =
  let librarian = lane ~no_slot:3 ~succeeded:7 ~failed:3 ~cancelled:0 [ slot "a" 7 ] in
  Alcotest.(check (list string)) "the runs that named no slot"
    [ "3 runs named no slot" ] (parts librarian)

(* Running rows are in none of the counts, so a lane mid-run does not report
   its running work as unaccounted. *)
let test_a_running_lane_does_not_count_its_running_work () =
  let running = lane ~running:3 ~succeeded:10 ~failed:0 ~cancelled:0 [ slot "a" 10 ] in
  Alcotest.(check int) "three running, all finished work counted" 0 (gap running);
  Alcotest.(check (list string)) "nothing is drawn" [] (parts running)

(* The server counts slots and slotless runs from the same finished runs, so
   they always add up. When they do not, the projection broke, and the line
   says by how much in either direction rather than rounding to nothing. *)
let test_counts_that_do_not_add_up_are_drawn () =
  let short = lane ~succeeded:9 ~failed:0 ~cancelled:0 [ slot "a" 5 ] in
  Alcotest.(check int) "four finished runs are in no count" 4 (gap short);
  Alcotest.(check (list string)) "the shortfall is drawn"
    [ "4 runs finished in no count" ] (parts short);
  let over = lane ~vendor_system_one:2 ~succeeded:5 ~failed:0 ~cancelled:0 [ slot "a" 9 ] in
  Alcotest.(check int) "six more counted than finished" (-6) (gap over);
  Alcotest.(check (list string)) "the excess is drawn, not hidden"
    [ "Vendor System One: 2"; "counts exceed finished runs by 6" ] (parts over)

(* A lane on which no finished run named a slot -- every answer came from
   Vendor System One -- still has a line to draw. *)
let test_a_lane_without_any_slot_still_says_who_answered () =
  let jev_only = lane ~vendor_system_one:7 ~succeeded:7 ~failed:0 ~cancelled:0 [] in
  Alcotest.(check int) "the counts cover every finished run" 0 (gap jev_only);
  Alcotest.(check (list string)) "the answers are drawn without a slot history"
    [ "Vendor System One: 7" ] (parts jev_only)

let () =
  Alcotest.run "masc_tui_lane_slot_reach"
    [ ( "slot history reach"
      , [ Alcotest.test_case "the Board lane names Vendor System One and restarts"
            `Quick test_the_board_lane_names_vendor_system_one_and_restarts
        ; Alcotest.test_case "a complete history adds nothing" `Quick
            test_a_complete_history_adds_nothing
        ; Alcotest.test_case "a run with no named reason is counted" `Quick
            test_a_run_with_no_named_reason_is_counted
        ; Alcotest.test_case "a running lane does not count its running work"
            `Quick test_a_running_lane_does_not_count_its_running_work
        ; Alcotest.test_case "counts that do not add up are drawn" `Quick
            test_counts_that_do_not_add_up_are_drawn
        ; Alcotest.test_case "a lane without any slot still says who answered"
            `Quick test_a_lane_without_any_slot_still_says_who_answered
        ] )
    ]
