(* The newest wake among a Keeper's schedule rows (RFC-0515 section 2.5). The
   screen text is not tested; the choice of which row's wake is the last is. *)

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

let newest_id rows =
  Option.map
    (fun (wake : Masc_tui_keeper_last_wake.t) ->
       wake.Masc_tui_keeper_last_wake.row.Masc_tui_types.sch_schedule_id)
    (Masc_tui_keeper_last_wake.newest rows)
;;

let id_option = Alcotest.(option string)

let test_no_rows () =
  Alcotest.check id_option "no rows, no wake" None (newest_id [])
;;

let test_rows_without_a_wake () =
  Alcotest.check id_option "rows that never woke are not candidates" None
    (newest_id [ make_row "a"; make_row "b" ])
;;

let test_latest_instant_wins_over_list_order () =
  Alcotest.check id_option "the later wake wins wherever it sits" (Some "b")
    (newest_id
       [ make_row ~wake_started_at_iso:"2026-11-07T09:00:00Z" "a"
       ; make_row ~wake_started_at_iso:"2026-11-07T10:00:00Z" "b"
       ; make_row "c"
       ])
;;

let test_equal_instants_keep_the_first_row () =
  Alcotest.check id_option "on a tie the server's order decides" (Some "a")
    (newest_id
       [ make_row ~wake_started_at_iso:"2026-11-07T09:00:00Z" "a"
       ; make_row ~wake_started_at_iso:"2026-11-07T09:00:00Z" "b"
       ])
;;

let test_offsets_compare_as_instants () =
  (* 10:00+09:00 is 01:00Z, earlier than 02:00Z although its text sorts later. *)
  Alcotest.check id_option "instants, not text" (Some "utc")
    (newest_id
       [ make_row ~wake_started_at_iso:"2026-11-07T10:00:00+09:00" "seoul"
       ; make_row ~wake_started_at_iso:"2026-11-07T02:00:00Z" "utc"
       ])
;;

let test_unreadable_time_is_skipped () =
  Alcotest.check id_option "a wake without a readable time cannot be placed" (Some "a")
    (newest_id
       [ make_row ~wake_started_at_iso:"2026-11-07T09:00:00Z" "a"
       ; make_row ~wake_started_at_iso:"zzz" "b"
       ]);
  (* Alone, it is not the newest of anything: no instant stands in for it. *)
  Alcotest.check id_option "an unreadable time alone names no wake" None
    (newest_id [ make_row ~wake_started_at_iso:"zzz" "b" ])
;;

let () =
  Alcotest.run "tui_keeper_last_wake"
    [ ( "newest"
      , [ Alcotest.test_case "no rows" `Quick test_no_rows
        ; Alcotest.test_case "rows without a wake" `Quick test_rows_without_a_wake
        ; Alcotest.test_case "latest instant wins" `Quick
            test_latest_instant_wins_over_list_order
        ; Alcotest.test_case "tie keeps the first row" `Quick
            test_equal_instants_keep_the_first_row
        ; Alcotest.test_case "offsets compare as instants" `Quick
            test_offsets_compare_as_instants
        ; Alcotest.test_case "unreadable time is skipped" `Quick
            test_unreadable_time_is_skipped
        ] )
    ]
;;
