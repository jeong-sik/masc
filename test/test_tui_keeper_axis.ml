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
    ?age_bins
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
  ; mkh_age_bins = age_bins
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
  ; mhs_total_source_snapshot_bytes = 512
  ; mhs_total_librarian_failures = 0
  ; mhs_total_librarian_unread_turns = Some 0
  ; mhs_total_librarian_continuity_unread_atoms = 0
  ; mhs_total_librarian_continuity_unmeasured = 0
  ; mhs_total_vision_ingest_errors = 0
  ; mhs_total_read_errors = 0
  ; mhs_total_source_read_errors = 0
  ; mhs_warn_alerts = 0
  ; mhs_error_alerts = 0
  ; mhs_starving_keepers = 0
  }
;;

(* The ladder cell goes last so a tight row drops it first. *)
let last_cell cells = List.nth_opt (List.rev cells) 0

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
    ; sch_recurrence = Ok Schedule_domain.One_shot
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
  let cells = Masc_tui_keeper_axis.segments state ~now ~keeper_name:"edgar" ~runtime:None in
  Alcotest.(check int) "has schedule cell + mem ?" 2 (List.length cells);
  (* The schedule cell counts down: the row is due at 12:00:00Z and now is 11:13:20Z. *)
  Alcotest.(check string) "first cell is schedule" "◷ 46m40s"
    (List.hd cells).Masc_tui_keeper_axis_cell.text;
  Alcotest.(check string) "second cell is mem ?" "mem ?"
    (List.nth cells 1).Masc_tui_keeper_axis_cell.text;
  (* The wake strip reads the same agenda: the 12:00:00Z run is two slots
     after the 11:00 slot that holds now. *)
  Alcotest.(check bool) "the wake strip reads the state's agenda" true
    (Masc_tui_keeper_axis.wake_strip state ~now ~ahead:2 ~keeper_name:"edgar"
     = Masc_tui_keeper_next_run.[ Wakes 0; Wakes 0; Wakes 1 ]);
  Alcotest.(check bool) "recurrence belongs to the unique exact next run" true
    (Masc_tui_keeper_axis.next_recurrence state ~keeper_name:"edgar" = Some Schedule_domain.One_shot);
  let agenda = state.schedules_agenda in
  state.schedules_agenda <- Option.map (fun snapshot ->
    { snapshot with Masc_tui_types.scs_rows = [ row; { row with sch_schedule_id = "same-due";
        sch_recurrence = Ok (Schedule_domain.Interval { interval_sec = 600 }) } ] }) agenda;
  Alcotest.(check bool) "equal due times do not choose an arbitrary recurrence" true
    (Masc_tui_keeper_axis.next_recurrence state ~keeper_name:"edgar" = None);
  state.schedules_agenda <- Option.map (fun snapshot ->
    { snapshot with Masc_tui_types.scs_rows = [ row; { row with sch_schedule_id = "unknown-status";
        sch_status = "not-understood" } ] }) agenda;
  Alcotest.(check bool) "unknown-status equal due remains an ambiguous candidate" true
    (Masc_tui_keeper_axis.next_recurrence state ~keeper_name:"edgar" = None);
  state.schedules_agenda <- agenda;
  (* A failed read keeps the last agenda on hand, and the strip does not
     vouch for it. *)
  state.schedules_agenda_error <- Some "agenda read failed";
  Alcotest.(check bool) "failed agenda read withdraws recurrence" true
    (Masc_tui_keeper_axis.next_recurrence state ~keeper_name:"edgar" = None);
  Alcotest.(check bool) "after a failed agenda read every slot is unknown" true
    (Masc_tui_keeper_axis.wake_strip state ~now ~ahead:2 ~keeper_name:"edgar"
     = Masc_tui_keeper_next_run.[ Wakes_unknown; Wakes_unknown; Wakes_unknown ]);
  state.schedules_agenda_error <- None;

  let other = Masc_tui_keeper_axis.segments state ~now ~keeper_name:"other" ~runtime:None in
  Alcotest.(check int) "unscheduled keeper has mem ?" 1 (List.length other);
  Alcotest.(check string) "unscheduled cell is mem ?" "mem ?"
    (List.hd other).Masc_tui_keeper_axis_cell.text;

  (* Now populate memory_health *)
  let lib = make_librarian ~unread_atom_turns:3 ~unread_official_turns:1 () in
  let kh = make_keeper_health ~keeper_id:"edgar" ~updated_at:(now -. 60.0) lib in
  state.memory_health <- Some (make_snapshot [ kh ]);

  let cells_with_memory = Masc_tui_keeper_axis.segments state ~now ~keeper_name:"edgar" ~runtime:None in
  (* edgar has: schedule cell, lag 4, +1m00s +2 -1, stale ×1, and the ladder
     cell last = 5 cells. The row carries no ladder, so that cell is the
     unmeasured one, not a zero. *)
  Alcotest.(check int) "edgar has schedule + lag + clock + stale + ladder" 5
    (List.length cells_with_memory);
  Alcotest.(check string) "edgar lag cell" "lag 4"
    (List.nth cells_with_memory 1).Masc_tui_keeper_axis_cell.text;
  Alcotest.(check string) "edgar clock cell" "+1m00s +2 -1"
    (List.nth cells_with_memory 2).Masc_tui_keeper_axis_cell.text;
  Alcotest.(check string) "edgar stale cell" "stale ×1"
    (List.nth cells_with_memory 3).Masc_tui_keeper_axis_cell.text;
  Alcotest.(check bool) "an unmeasured ladder is the last cell" true
    (last_cell cells_with_memory = Some (Masc_tui_keeper_age_ladder.cell None));

  (* The server's ladder replaces the unmeasured cell, still last. *)
  let bins =
    Masc.Keeper_memory_age_bins.of_first_seen ~now [ now; now -. 7200.0; now -. 90000.0 ]
  in
  let kh_with_bins =
    make_keeper_health ~keeper_id:"edgar" ~updated_at:(now -. 60.0) ~age_bins:bins lib
  in
  state.memory_health <- Some (make_snapshot [ kh_with_bins ]);
  let cells_with_ladder =
    Masc_tui_keeper_axis.segments state ~now ~keeper_name:"edgar" ~runtime:None
  in
  Alcotest.(check int) "a ladder does not add a cell" 5 (List.length cells_with_ladder);
  Alcotest.(check bool) "the ladder cell is drawn from the row's bins" true
    (last_cell cells_with_ladder = Some (Masc_tui_keeper_age_ladder.cell (Some bins)));

  (* A refused Keeper has the refusal cell and no ladder. *)
  let refusal : Tui_decode_memory_health.memory_keeper_refusal =
    { mkr_keeper_id = Some "gamma"; mkr_reason = "corrupt snapshot" }
  in
  state.memory_health <- Some (make_snapshot ~refusals:[ refusal ] [ kh_with_bins ]);
  let refused = Masc_tui_keeper_axis.segments state ~now ~keeper_name:"gamma" ~runtime:None in
  Alcotest.(check int) "a refused keeper has one cell and no ladder" 1 (List.length refused);
  state.memory_health <- Some (make_snapshot [ kh ]);

  (* other is absent from snapshot without anonymous refusal -> No_row (0 cells) *)
  let other_clean = Masc_tui_keeper_axis.segments state ~now ~keeper_name:"other" ~runtime:None in
  Alcotest.(check int) "other has 0 cells when absent from snapshot" 0 (List.length other_clean)
;;

(* Column widths of the cells in the order the row draws them, as #50022
   counts them: failing, schedule, the four memory cells, pulse, ladder. *)
let widest_row = [ 14; 18; 5; 5; 13; 8; 12; 13 ]
let healthy_row = [ 8; 5; 12; 12; 13 ]

let fit ~available ~detail_floor widths =
  let { Masc_tui_keeper_axis_cell.drawn; left_width; _ } =
    Masc_tui_keeper_axis_cell.fit ~available ~detail_floor ~width:Fun.id widths
  in
  drawn, left_width
;;

let test_fit_leaves_the_detail_its_floor () =
  let drawn_left = Alcotest.(pair (list int) int) in
  (* Without a floor the widest row at 80 columns (73 after the marker) draws
     six cells and leaves the DETAIL nothing. *)
  Alcotest.check drawn_left "no floor"
    ([ 14; 18; 5; 5; 13; 8 ], 0)
    (fit ~available:73 ~detail_floor:None widest_row);
  (* With DETAIL text the last cells go until the DETAIL has its floor. *)
  Alcotest.check drawn_left "a floor of 10"
    ([ 14; 18; 5; 5 ], 24)
    (fit ~available:73 ~detail_floor:(Some 10) widest_row);
  (* A row whose cells fit with room to spare is not changed. *)
  Alcotest.check drawn_left "healthy row"
    (healthy_row, 14)
    (fit ~available:73 ~detail_floor:(Some 10) healthy_row);
  (* The first cell stays even when it leaves the DETAIL less than the floor,
     and a row too narrow for it draws none. *)
  Alcotest.check drawn_left "first cell stays" ([ 14 ], 5)
    (fit ~available:20 ~detail_floor:(Some 10) [ 14; 5 ]);
  Alcotest.check drawn_left "too narrow for the first cell" ([], 10)
    (fit ~available:10 ~detail_floor:(Some 10) [ 14; 5 ]);
  (* At every width a second cell is drawn only when the DETAIL keeps its
     floor, and the cells drawn are the ones the row draws without a floor,
     minus the last ones. *)
  List.iter
    (fun widths ->
      for available = 0 to 200 do
        let drawn, left = fit ~available ~detail_floor:(Some 10) widths in
        let all, _ = fit ~available ~detail_floor:None widths in
        let kept = List.length drawn in
        Alcotest.(check bool)
          (Printf.sprintf "%d of %d cells at %d columns" kept (List.length widths) available)
          true
          ((kept <= 1 || left >= 10) && drawn = List.filteri (fun i _ -> i < kept) all)
      done)
    [ widest_row; healthy_row ]
;;

module Axis = Masc_tui_keeper_axis
module Model = Masc_tui_keeper_list_model
module Next_run = Masc_tui_keeper_next_run
module Reading = Masc_tui_keeper_memory_reading

let hour = 3600.
let reading_now = 1_794_000_000.

let memory_row ?(lag = Reading.Lag 0) ?(gap = Reading.No_gap) ?updated_at () =
  Reading.Row
    { state = Masc_tui_types.Memory_ordinary
    ; lag
    ; gap
    ; digest_at = None
    ; updated_at
    ; added = 0
    ; removed = 0
    ; source_invalidations = 0
    ; age_bins = None
    ; pass_end = None
    }
;;

let due_label = function
  | Model.Due_late -> "late"
  | Model.Due_held -> "held"
  | Model.Due_within_hour -> "hour"
  | Model.Due_within_half_day -> "half day"
  | Model.Due_later -> "later"
  | Model.Due_none -> "none"
  | Model.Due_unknown -> "unknown"
;;

let test_due_buckets_every_next_run_reading () =
  let due reading = due_label (Axis.due_of_next_run ~now:reading_now reading) in
  let ahead seconds = reading_now +. seconds in
  Alcotest.(check (list string)) "every next-run reading has a time bucket"
    [ "none"; "unknown"; "late"; "held"; "held"
    ; "hour"; "hour"; "half day"; "half day"; "later"
    ; "unknown"; "later" ]
    (List.map due
       [ Next_run.No_schedule
       ; Next_run.Unknown
       ; Next_run.Late_since (ahead (-.hour))
       ; Next_run.Held_current (ahead hour)
       ; Next_run.Held_as_of (ahead hour)
       ; Next_run.Scheduled_at (ahead (-.60.))
       ; Next_run.Scheduled_at (ahead hour)
       ; Next_run.Scheduled_at (ahead (hour +. 1.))
       ; Next_run.Scheduled_at (ahead (12. *. hour))
       ; Next_run.Scheduled_at (ahead ((12. *. hour) +. 1.))
       ; Next_run.Not_before (ahead (12. *. hour))
       ; Next_run.Not_before (ahead ((12. *. hour) +. 1.))
       ])
;;

let follow_label = function
  | Model.Memory_refused -> "refused"
  | Model.Memory_gap -> "gap"
  | Model.Memory_lagging -> "lagging"
  | Model.Memory_following -> "following"
  | Model.Memory_unread -> "unread"
;;

let test_follow_puts_a_gap_before_lag () =
  Alcotest.(check (list string)) "gap, lag, following and unread readings"
    [ "unread"; "unread"; "refused"; "gap"; "gap"; "lagging"; "following"; "unread" ]
    (List.map
       (fun reading -> follow_label (Axis.follow_of_memory reading))
       [ Reading.Unknown
       ; Reading.No_row
       ; Reading.Refused "anonymous"
       ; memory_row ~lag:(Reading.Lag 0) ~gap:(Reading.Gap { first_atom = 3; past_last_atom = 5 }) ()
       ; memory_row ~lag:(Reading.Lag 4) ~gap:Reading.Gap_unmeasured ()
       ; memory_row ~lag:(Reading.Lag 2) ()
       ; memory_row ~lag:(Reading.Lag 0) ()
       ; memory_row ~lag:Reading.Lag_unmeasured ()
       ])
;;

let age_label = function
  | Model.Age_within_3h -> "3h"
  | Model.Age_within_day -> "24h"
  | Model.Age_within_3d -> "3d"
  | Model.Age_older -> "older"
  | Model.Age_unknown -> "unknown"
;;

let test_age_buckets_the_last_update () =
  let updated ago = memory_row ~updated_at:(reading_now -. ago) () in
  Alcotest.(check (list string)) "the bounds belong to the nearer bucket"
    [ "unknown"; "unknown"; "3h"; "3h"; "24h"; "24h"; "3d"; "3d"; "older" ]
    (List.map
       (fun reading -> age_label (Axis.age_of_memory ~now:reading_now reading))
       [ Reading.No_row
       ; memory_row ()
       ; updated (-.60.)
       ; updated (3. *. hour)
       ; updated ((3. *. hour) +. 1.)
       ; updated (24. *. hour)
       ; updated ((24. *. hour) +. 1.)
       ; updated (72. *. hour)
       ; updated ((72. *. hour) +. 1.)
       ])
;;

module Strip = Masc_tui_keeper_strip
module Control = Masc_tui_keeper_control

let strip_runtime ~health ?(paused = false) ?recent_turns name : Tui_decode.keeper_runtime =
  { kr_name = name
  ; kr_identity = Ok { k_trace_id = "trace-" ^ name; k_created_at = "2026-01-01T00:00:00Z"; k_updated_at = "2026-01-01T00:00:00Z" }
  ; kr_portrait = Tui_decode.Unavailable "test"
  ; kr_candle_account_revision = Ok None
  ; kr_health = Option.get (Tui_decode.keeper_health_of_string health)
  ; kr_paused = paused
  ; kr_next_action = None
  ; kr_keepalive_running = true
  ; kr_activation_mode = Tui_decode.Activation_autonomous
  ; kr_runtime_id = "test.runtime"
  ; kr_phase = Option.get (Tui_decode.keeper_phase_of_string "running")
  ; kr_sandbox_profile = "docker"
  ; kr_runtime_blocker_summary = None
  ; kr_last_failure = None
  ; kr_runtime_blocker_signature = None
  ; kr_runtime_lane_observation = None
  ; kr_runtime_path_rest = Ok None
  ; kr_operator_disposition = Ok None
  ; kr_failing_since = None
  ; kr_recent_turns = recent_turns
  }
;;

let strip_row ~liveness name : Model.row =
  let paused =
    match liveness with
    | Control.Present rt -> rt.Tui_decode.kr_paused
    | Control.Absent | Control.Unobserved | Control.Invalid _ -> false
  in
  { keeper =
      { k_origin = Tui_decode.Persisted_keeper
      ; k_name = name
      ; k_paused = paused
      ; k_identity = Error "not needed"
      ; k_activity = None
      }
  ; reading = { Control.name = name; paused; liveness }
  ; turn = None
  ; waiting = Model.Waiting_unobserved
  ; approval = None
  ; task = None
  ; awaiting_verification = false
  ; open_questions = 0
  ; async_requests = []
  ; last_activity_at = Some reading_now
  }
;;

let contains_substring ~needle haystack =
  let nlen = String.length needle in
  let hlen = String.length haystack in
  let rec loop i =
    if i + nlen > hlen then false
    else if String.sub haystack i nlen = needle then true
    else loop (i + 1)
  in
  loop 0
;;

let test_header_preserves_every_group_count_on_large_rosters () =
  let slot_start = Keeper_turn_pulse.slot_start reading_now in
  let recent_recovery : Keeper_turn_pulse.pulse =
    { known_since = reading_now -. (24. *. hour)
    ; slots = [ { starts_at = slot_start; tally = { ok = 1; rested = 0; failed = 1 } } ]
    }
  in
  List.iter
    (fun total ->
      let n_fail = total * 2 / 5 in
      let n_rec = max 1 (total / 10) in
      let n_ok = total * 3 / 10 in
      let n_paused = max 1 (total / 10) in
      let n_unknown = total - n_fail - n_rec - n_ok - n_paused in
      let make_group prefix count make_liveness =
        List.init count (fun idx ->
          let name = Printf.sprintf "%s-%d" prefix idx in
          strip_row ~liveness:(make_liveness name) name)
      in
      let rows =
        make_group "fail" n_fail (fun n -> Control.Present (strip_runtime ~health:"failing" n))
        @ make_group "rec" n_rec (fun n ->
            Control.Present (strip_runtime ~health:"healthy" ~recent_turns:recent_recovery n))
        @ make_group "ok" n_ok (fun n -> Control.Present (strip_runtime ~health:"healthy" n))
        @ make_group "pause" n_paused (fun n ->
            Control.Present (strip_runtime ~health:"healthy" ~paused:true n))
        @ make_group "unk" n_unknown (fun _ -> Control.Unobserved)
      in
      let last_ok = Printf.sprintf "ok-%d" (n_ok - 1) in
      List.iter
        (fun cells ->
          let rendered =
            Strip.header ~now:reading_now ~cells ~view:Model.By_state
              ~selected:(Some last_ok) ~age:(fun _ -> Model.Age_within_3h) rows
          in
          let plain = Masc_tui_ansi.Terminal_text.strip_ansi rendered in
          let width = Masc_tui_message_layout.display_width plain in
          Alcotest.(check bool)
            (Printf.sprintf "total=%d cells=%d fits within cells (got %d)" total cells width)
            true
            (width <= cells);
          List.iter
            (fun token ->
              Alcotest.(check bool)
                (Printf.sprintf "total=%d cells=%d preserves group count %s in %S" total cells token plain)
                true
                (contains_substring ~needle:token plain))
            [ Printf.sprintf "!%d" n_fail
            ; Printf.sprintf "✓%d" n_rec
            ; Printf.sprintf "●%d" n_ok
            ; Printf.sprintf "○%d" n_paused
            ; Printf.sprintf "?%d" n_unknown
            ];
          Alcotest.(check bool)
            (Printf.sprintf "total=%d cells=%d preserves bold mark for selected tail keeper" total cells)
            true
            (contains_substring ~needle:(Masc_tui_ansi.Ansi.bold ^ "▪") rendered);
          let age_for (r : Model.row) =
            let k = r.keeper.Tui_decode.k_name in
            if String.starts_with ~prefix:"fail-" k then Model.Age_within_3h
            else if String.starts_with ~prefix:"rec-" k then Model.Age_within_day
            else if String.starts_with ~prefix:"ok-" k then Model.Age_within_3d
            else if String.starts_with ~prefix:"pause-" k then Model.Age_older
            else Model.Age_unknown
          in
          let rendered_age =
            Strip.header ~now:reading_now ~cells ~view:Model.By_age
              ~selected:(Some last_ok) ~age:age_for rows
          in
          let plain_age = Masc_tui_ansi.Terminal_text.strip_ansi rendered_age in
          let width_age = Masc_tui_message_layout.display_width plain_age in
          Alcotest.(check bool)
            (Printf.sprintf "By_age total=%d cells=%d fits within cells (got %d)" total cells width_age)
            true
            (width_age <= cells);
          List.iter
            (fun token ->
              Alcotest.(check bool)
                (Printf.sprintf "By_age total=%d cells=%d preserves group count %s in %S" total cells token plain_age)
                true
                (contains_substring ~needle:token plain_age))
            [ Printf.sprintf "█%d" n_fail
            ; Printf.sprintf "▆%d" n_rec
            ; Printf.sprintf "▃%d" n_ok
            ; Printf.sprintf "▁%d" n_paused
            ; Printf.sprintf "?%d" n_unknown
            ])
        [ 78; 80; 118; 120 ])
    [ 40; 100; 300 ]
;;

let () =
  Alcotest.run "tui_keeper_axis"
    [ ( "axis segments"
      , [ Alcotest.test_case "extracts scheduled and memory cells" `Quick
            test_segments_extracts_scheduled_and_memory_cells
        ] )
    ; ( "axis cell fit"
      , [ Alcotest.test_case "leaves the DETAIL its floor" `Quick
            test_fit_leaves_the_detail_its_floor
        ] )
    ; ( "view readings"
      , [ Alcotest.test_case "every next-run reading has a time bucket" `Quick
            test_due_buckets_every_next_run_reading
        ; Alcotest.test_case "a gap comes before lag" `Quick test_follow_puts_a_gap_before_lag
        ; Alcotest.test_case "age bounds belong to the nearer bucket" `Quick
            test_age_buckets_the_last_update
        ; Alcotest.test_case "header reserves every group count before marks at 40/100/300 keepers" `Quick
            test_header_preserves_every_group_count_on_large_rosters
        ] )
    ]
