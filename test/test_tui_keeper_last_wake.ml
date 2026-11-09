(* The last wake told from one page of a Keeper's schedule rows (RFC-0515
   section 2.5). The screen text is not tested; which wake the page lets the
   story page call the last, and whether it may call one at all, is. *)

let make_row ?wake_started_at_iso id : Masc_tui_types.schedule_row =
  { sch_schedule_id = id
  ; sch_schedule_instance_id = "inst-" ^ id
  ; sch_status = "scheduled"
  ; sch_source = "operator_request"
  ; sch_requested_by = "operator"
  ; sch_scheduled_by = "operator"
  ; sch_requested_at_iso = "2026-11-07T00:00:00Z"
  ; sch_due_at_iso = None
  ; sch_next_due_at_iso = None
  ; sch_expires_at_iso = None
  ; sch_recurrence_summary = ""
  ; sch_recurrence = `Assoc []
  ; sch_payload_digest = "digest"
  ; sch_payload = `Assoc []
  ; sch_payload_kind = None
  ; sch_payload_support = "supported"
  ; sch_payload_dispatch_tool = None
  ; sch_payload_target = None
  ; sch_payload_keeper_name = None
  ; sch_payload_summary = None
  ; sch_last_wake_status =
      Option.map (fun _ -> Schedule_contract_values.Wake_succeeded) wake_started_at_iso
  ; sch_last_wake_started_at_iso = wake_started_at_iso
  ; sch_last_wake_error = None
  ; sch_queue_projection_status = None
  ; sch_queue_pending_count = None
  ; sch_reaction_projection_status = None
  ; sch_reaction_latest_at_iso = None
  ; sch_reaction_kind = None
  ; sch_reaction_keeper_name = None
  ; sch_reaction_stimulus_id = None
  ; sch_reaction_post_id = None
  ; sch_reaction_reason = None
  ; sch_wake_seen = None
  ; sch_turn_started = None
  ; sch_turn_finished = None
  ; sch_queue_ack_seen = None
  ; sch_wake_cancelled = None
  ; sch_stimulus_recorded_at_iso = None
  ; sch_turn_started_recorded_at_iso = None
  ; sch_turn_finished_recorded_at_iso = None
  ; sch_queue_ack_recorded_at_iso = None
  ; sch_wake_cancelled_recorded_at_iso = None
  ; sch_reaction_quarantined = None
  ; sch_occurrence =
      { Masc.Tui_schedule_observation.stage = Masc.Tui_schedule_observation.No_occurrence
      ; due_at_iso = None
      }
  ; sch_runner_hold = None
  }
;;

let describe = function
  | Masc_tui_keeper_last_wake.No_wake -> "no wake"
  | Masc_tui_keeper_last_wake.Not_on_first_page -> "not on the first page"
  | Masc_tui_keeper_last_wake.Newest wake ->
      "newest " ^ (Masc_tui_keeper_last_wake.row wake).Masc_tui_types.sch_schedule_id
  | Masc_tui_keeper_last_wake.Newest_on_first_page wake ->
      "newest on the first page "
      ^ (Masc_tui_keeper_last_wake.row wake).Masc_tui_types.sch_schedule_id
  | Masc_tui_keeper_last_wake.Unplaced -> "unplaced"
;;

let reading ?(truncated = false) rows =
  describe (Masc_tui_keeper_last_wake.of_page ~truncated rows)
;;

let test_no_rows () =
  Alcotest.check Alcotest.string "no rows, no wake" "no wake" (reading [])
;;

let test_rows_without_a_wake () =
  Alcotest.check Alcotest.string "rows that never woke are not candidates" "no wake"
    (reading [ make_row "a"; make_row "b" ])
;;

let test_latest_instant_wins_over_list_order () =
  Alcotest.check Alcotest.string "the later wake wins wherever it sits" "newest b"
    (reading
       [ make_row ~wake_started_at_iso:"2026-11-07T09:00:00Z" "a"
       ; make_row ~wake_started_at_iso:"2026-11-07T10:00:00Z" "b"
       ; make_row "c"
       ])
;;

let test_equal_instants_keep_the_first_row () =
  Alcotest.check Alcotest.string "on a tie the server's order decides" "newest a"
    (reading
       [ make_row ~wake_started_at_iso:"2026-11-07T09:00:00Z" "a"
       ; make_row ~wake_started_at_iso:"2026-11-07T09:00:00Z" "b"
       ])
;;

let test_offsets_compare_as_instants () =
  (* 10:00+09:00 is 01:00Z, earlier than 02:00Z although its text sorts later. *)
  Alcotest.check Alcotest.string "instants, not text" "newest utc"
    (reading
       [ make_row ~wake_started_at_iso:"2026-11-07T10:00:00+09:00" "seoul"
       ; make_row ~wake_started_at_iso:"2026-11-07T02:00:00Z" "utc"
       ])
;;

let test_unreadable_time_leaves_the_last_wake_unknown () =
  (* The wake with the unreadable time may be the newest, so the readable one
     beside it is not the last wake. *)
  Alcotest.check Alcotest.string "a wake without a readable time cannot be placed" "unplaced"
    (reading
       [ make_row ~wake_started_at_iso:"2026-11-07T09:00:00Z" "a"
       ; make_row ~wake_started_at_iso:"zzz" "b"
       ]);
  Alcotest.check Alcotest.string "an unreadable time alone is not a wake of no time"
    "unplaced"
    (reading [ make_row ~wake_started_at_iso:"zzz" "b" ]);
  Alcotest.check Alcotest.string "a status without a start time is a wake too" "unplaced"
    (reading
       [ { (make_row "r") with
           sch_last_wake_status = Some Schedule_contract_values.Wake_running
         }
       ])
;;

let test_a_cut_page_says_so () =
  Alcotest.check Alcotest.string "a cut page with no wake leaves a later page open"
    "not on the first page"
    (reading ~truncated:true [ make_row "a" ]);
  Alcotest.check Alcotest.string
    "the latest wake of a cut page is not called the last" "newest on the first page b"
    (reading ~truncated:true
       [ make_row ~wake_started_at_iso:"2026-11-07T09:00:00Z" "a"
       ; make_row ~wake_started_at_iso:"2026-11-07T10:00:00Z" "b"
       ]);
  Alcotest.check Alcotest.string "an unplaced wake outranks the cut" "unplaced"
    (reading ~truncated:true [ make_row ~wake_started_at_iso:"zzz" "b" ])
;;

let () =
  Alcotest.run "tui_keeper_last_wake"
    [ ( "of_page"
      , [ Alcotest.test_case "no rows" `Quick test_no_rows
        ; Alcotest.test_case "rows without a wake" `Quick test_rows_without_a_wake
        ; Alcotest.test_case "latest instant wins" `Quick
            test_latest_instant_wins_over_list_order
        ; Alcotest.test_case "tie keeps the first row" `Quick
            test_equal_instants_keep_the_first_row
        ; Alcotest.test_case "offsets compare as instants" `Quick
            test_offsets_compare_as_instants
        ; Alcotest.test_case "unreadable time leaves the last wake unknown" `Quick
            test_unreadable_time_leaves_the_last_wake_unknown
        ; Alcotest.test_case "a cut page says so" `Quick test_a_cut_page_says_so
        ] )
    ]
;;
