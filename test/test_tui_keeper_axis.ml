open Masc

let make_librarian
    ?unread_atom_turns
    ?unread_official_turns
    ?stalled
    ?last_success_at
    () : Tui_decode_memory_health.memory_librarian_health =
  { mlh_state = None
  ; mlh_measured_at = None
  ; mlh_unread_atom_turns = unread_atom_turns
  ; mlh_unread_official_turns = unread_official_turns
  ; mlh_continuity_unread_atoms = None
  ; mlh_last_success_at = last_success_at
  ; mlh_last_failure_kind = None
  ; mlh_stalled = stalled
  }
;;

let make_keeper_health
    ?(keeper_id = "edgar")
    ?(added = 2)
    ?(removed = 1)
    ?(source_invalidations = 1)
    ?updated_at
    librarian : Tui_decode_memory_health.memory_keeper_health =
  { mkh_keeper_id = keeper_id
  ; mkh_revision = 1
  ; mkh_updated_at = updated_at
  ; mkh_facts = 10
  ; mkh_observed_facts = 8
  ; mkh_derived_facts = 2
  ; mkh_support_invalidations = 0
  ; mkh_snapshot_bytes = 1024
  ; mkh_added = added
  ; mkh_removed = removed
  ; mkh_snapshot_present = true
  ; mkh_context_cycle =
      { mcc_saved = None
      ; mcc_saved_unreadable = false
      ; mcc_read_position = None
      ; mcc_read_position_unreadable = false
      ; mcc_rewriting_through = None
      ; mcc_unread_snapshot = Ok []
      ; mcc_unread_memory = Ok []
      ; mcc_prepared = None
      ; mcc_synthesis = None
      }
  ; mkh_librarian = librarian
  ; mkh_librarian_failures = 0
  ; mkh_vision_ingest_errors = 0
  ; mkh_vision_ingest_error_reasons = []
  ; mkh_read_error = None
  ; mkh_source_revision = 1
  ; mkh_source_facts = 5
  ; mkh_source_invalidations = source_invalidations
  ; mkh_source_snapshot_bytes = 512
  ; mkh_source_snapshot_present = true
  ; mkh_source_read_error = None
  ; mkh_alerts = []
  }
;;

let make_snapshot ?(refusals = []) keepers : Tui_decode_memory_health.memory_health_snapshot =
  { mhs_generated_at = 1794050000.0
  ; mhs_keepers = keepers
  ; mhs_refused_keepers = refusals
  ; mhs_total_facts = 10
  ; mhs_total_observed_facts = 8
  ; mhs_total_derived_facts = 2
  ; mhs_total_support_invalidations = 0
  ; mhs_total_snapshot_bytes = 1024
  ; mhs_total_source_facts = 5
  ; mhs_total_source_invalidations = 0
  ; mhs_execution = None
  }
;;

let test_segments_extracts_scheduled_and_memory_cells () =
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
  (* When memory_health is None, memory reading is Unknown ("mem ?") *)
  let cells = Masc_tui_keeper_axis.segments state ~now ~keeper_name:"edgar" in
  Alcotest.(check int) "has schedule cell + mem ?" 2 (List.length cells);
  Alcotest.(check string) "first cell is schedule" "◷ 12:00:00"
    (List.hd cells).Masc_tui_keeper_axis_cell.text;
  Alcotest.(check string) "second cell is mem ?" "mem ?"
    (List.nth cells 1).Masc_tui_keeper_axis_cell.text;

  let other = Masc_tui_keeper_axis.segments state ~now ~keeper_name:"other" in
  Alcotest.(check int) "unscheduled keeper has mem ?" 1 (List.length other);
  Alcotest.(check string) "unscheduled cell is mem ?" "mem ?"
    (List.hd other).Masc_tui_keeper_axis_cell.text;

  (* Now populate memory_health *)
  let lib = make_librarian ~unread_atom_turns:3 ~unread_official_turns:1 () in
  let kh = make_keeper_health ~keeper_id:"edgar" ~updated_at:(now -. 60.0) lib in
  state.memory_health <- Some (make_snapshot [ kh ]);

  let cells_with_memory = Masc_tui_keeper_axis.segments state ~now ~keeper_name:"edgar" in
  (* edgar has: schedule cell, lag 4, +1m +2 -1, stale ×1 = 4 cells *)
  Alcotest.(check int) "edgar has schedule + lag + clock + stale" 4 (List.length cells_with_memory);
  Alcotest.(check string) "edgar lag cell" "lag 4"
    (List.nth cells_with_memory 1).Masc_tui_keeper_axis_cell.text;
  Alcotest.(check string) "edgar clock cell" "+1m +2 -1"
    (List.nth cells_with_memory 2).Masc_tui_keeper_axis_cell.text;
  Alcotest.(check string) "edgar stale cell" "stale ×1"
    (List.nth cells_with_memory 3).Masc_tui_keeper_axis_cell.text;

  (* other is absent from snapshot without anonymous refusal -> No_row (0 cells) *)
  let other_clean = Masc_tui_keeper_axis.segments state ~now ~keeper_name:"other" in
  Alcotest.(check int) "other has 0 cells when absent from snapshot" 0 (List.length other_clean)
;;

let () =
  Alcotest.run "tui_keeper_axis"
    [ ( "axis segments"
      , [ Alcotest.test_case "extracts scheduled and memory cells" `Quick
            test_segments_extracts_scheduled_and_memory_cells
        ] )
    ]
