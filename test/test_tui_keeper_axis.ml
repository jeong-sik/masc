let test_segments_extracts_scheduled_cell () =
  let state = Masc_tui_types.create_state ~workspace:"test" ~port:8935 () in
  let row : Masc_tui_types.schedule_row =
    { sch_schedule_id = "sch-1"
    ; sch_schedule_instance_id = "inst-1"
    ; sch_status = "scheduled"
    ; sch_source = "operator"
    ; sch_requested_by = "operator"
    ; sch_scheduled_by = "operator"
    ; sch_requested_at_iso = "2026-11-07T00:00:00Z"
    ; sch_due_at_iso = Some "2026-11-07T12:00:00Z"
    ; sch_next_due_at_iso = Some "2026-11-07T12:00:00Z"
    ; sch_expires_at_iso = None
    ; sch_recurrence_summary = ""
    ; sch_recurrence = `Assoc []
    ; sch_payload_digest = "digest"
    ; sch_payload = `Assoc []
    ; sch_payload_kind = None
    ; sch_payload_support = "supported"
    ; sch_payload_dispatch_tool = None
    ; sch_payload_target = None
    ; sch_payload_keeper_name = Some "edgar"
    ; sch_payload_summary = None
    ; sch_last_wake_status = None
    ; sch_last_wake_started_at_iso = None
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
        { Masc.Tui_schedule_observation.stage = No_occurrence
        ; due_at_iso = None
        }
    ; sch_runner_hold = None
    }
  in
  state.schedules_agenda <- Some
    { scs_observed_at_iso = "2026-11-07T10:00:00Z"
    ; scs_status = "ok"
    ; scs_read_error = None
    ; scs_request_count = Some 1
    ; scs_truncated = false
    ; scs_payload_target = None
    ; scs_paging = Schedule_paging_unavailable
    ; scs_next_due_iso = None
    ; scs_counts = None
    ; scs_rows = [ row ]
    ; scs_runner_status = Masc.Tui_decode.Runner_status Schedule_contract_values.Runner_ok
    };
  let now = 1794050000.0 in
  let cells = Masc_tui_keeper_axis.segments state ~now ~keeper_name:"edgar" in
  Alcotest.(check int) "has 1 schedule cell" 1 (List.length cells);
  let other = Masc_tui_keeper_axis.segments state ~now ~keeper_name:"other" in
  Alcotest.(check int) "unscheduled keeper has 0 cells" 0 (List.length other)
;;

let () =
  Alcotest.run "tui_keeper_axis"
    [ ( "axis segments"
      , [ Alcotest.test_case "extracts scheduled cell" `Quick
            test_segments_extracts_scheduled_cell
        ] )
    ]
