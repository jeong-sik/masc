let make_row
    ?(id = "sch-1")
    ?(status = "scheduled")
    ?due_at_iso
    ?next_due_at_iso
    ?payload_target
    ?keeper_name
    ?runner_hold
    ?(occurrence_stage = Masc.Tui_schedule_observation.No_occurrence)
    ?occurrence_due_at_iso
    ?expires_at_iso
    ?(recurrence = Ok Schedule_domain.One_shot)
    () : Masc_tui_types.schedule_row =
  { sch_schedule_id = id
  ; sch_schedule_instance_id = "inst-1"
  ; sch_status = status
  ; sch_source = "operator_request"
  ; sch_requested_by = "operator"
  ; sch_scheduled_by = "operator"
  ; sch_requested_at_iso = "2026-11-07T00:00:00Z"
  ; sch_due_at_iso = due_at_iso
  ; sch_next_due_at_iso = next_due_at_iso
  ; sch_expires_at_iso = expires_at_iso
  ; sch_recurrence_summary = ""
  ; sch_recurrence = recurrence
  ; sch_payload_digest = "digest"
  ; sch_payload = `Assoc []
  ; sch_payload_kind = None
  ; sch_payload_support = "supported"
  ; sch_payload_dispatch_tool = None
  ; sch_payload_target = payload_target
  ; sch_payload_keeper_name = keeper_name
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
      { Masc.Tui_schedule_observation.stage = occurrence_stage
      ; due_at_iso = occurrence_due_at_iso
      }
  ; sch_runner_hold = runner_hold
  }
;;

let make_snapshot
    ?(status = "ok")
    ?read_error
    ?(truncated = false)
    ?(runner_status = Masc.Tui_decode.Runner_status Schedule_contract_values.Runner_ok)
    rows : Masc_tui_types.schedule_snapshot =
  { scs_observed_at_iso = "2026-11-07T10:00:00Z"
  ; scs_status = status
  ; scs_read_error = read_error
  ; scs_request_count = Some (List.length rows)
  ; scs_truncated = truncated
  ; scs_payload_target = None
  ; scs_paging = Schedule_paging_unavailable
  ; scs_next_due_iso = None
  ; scs_counts = None
  ; scs_rows = rows
  ; scs_runner_status = runner_status
  }
;;

let test_seven_branches () =
  let now = 1794050000.0 in
  let scheduled_due = 1794053600.0 in (* 1 hour after now *)
  let hold_observed = 1794049000.0 in

  let runner_ok = Masc.Tui_decode.Runner_status Schedule_contract_values.Runner_ok in

  let hold : Masc.Tui_decode.schedule_runner_hold =
    { srh_occurrence_id = "occ-1"
    ; srh_due_at_iso = "2026-11-07T10:00:00Z"
    ; srh_reason = Masc.Tui_decode.Hold_previous_wake_untaken
    ; srh_observed_at = hold_observed
    }
  in

  (* 1. No_schedule *)
  let snap_empty = make_snapshot [] in
  let t_empty =
    Masc_tui_keeper_next_run.of_snapshot
      ~freshness:Masc_tui_agenda.Last_read
      ~keeper_name:"alpha"
      snap_empty
  in
  Alcotest.(check bool) "empty snapshot yields No_schedule"
    true (t_empty = Masc_tui_keeper_next_run.No_schedule);
  Alcotest.(check bool) "No_schedule produces no cell"
    true (Masc_tui_keeper_next_run.cell ~now t_empty = None);

  (* 2. Scheduled_at *)
  let row_sched =
    make_row
      ~status:"scheduled"
      ~due_at_iso:"2026-11-07T11:00:00Z"
      ~next_due_at_iso:"2026-11-07T11:00:00Z"
      ~keeper_name:"alpha"
      ()
  in
  let snap_sched = make_snapshot [ row_sched ] in
  let t_sched =
    Masc_tui_keeper_next_run.of_snapshot
      ~freshness:Masc_tui_agenda.Last_read
      ~keeper_name:"alpha"
      snap_sched
  in
  (match t_sched with
   | Masc_tui_keeper_next_run.Scheduled_at ts ->
       Alcotest.(check bool) "valid timestamp" true (ts > 0.0)
   | _ -> Alcotest.fail "expected Scheduled_at");
  (match Masc_tui_keeper_next_run.cell ~now:scheduled_due t_sched with
   | Some cell ->
       Alcotest.(check bool) "Scheduled_at has Quiet tone"
         true (cell.tone = Masc_tui_keeper_axis_cell.Quiet)
   | None -> Alcotest.fail "expected cell for Scheduled_at");

  (* 3. Late_since *)
  let row_late =
    make_row
      ~status:"due"
      ~due_at_iso:"2026-11-07T09:00:00Z"
      ~keeper_name:"alpha"
      ()
  in
  let snap_late = make_snapshot [ row_late ] in
  let t_late =
    Masc_tui_keeper_next_run.of_snapshot
      ~freshness:Masc_tui_agenda.Last_read
      ~keeper_name:"alpha"
      snap_late
  in
  (match t_late with
   | Masc_tui_keeper_next_run.Late_since ts ->
       Alcotest.(check bool) "valid late timestamp" true (ts > 0.0)
   | _ -> Alcotest.fail "expected Late_since");
  (match Masc_tui_keeper_next_run.cell ~now t_late with
   | Some cell ->
       Alcotest.(check bool) "Late_since has Attention tone"
         true (cell.tone = Masc_tui_keeper_axis_cell.Attention);
       Alcotest.(check bool) "Late_since text mentions 늦음"
         true (String.starts_with ~prefix:"◷ 늦음" cell.text)
   | None -> Alcotest.fail "expected cell for Late_since");

  (* 4. Held_current *)
  let row_hold_curr =
    make_row
      ~status:"due"
      ~due_at_iso:"2026-11-07T10:00:00Z"
      ~keeper_name:"alpha"
      ~runner_hold:hold
      ()
  in
  let snap_hold_curr = make_snapshot ~runner_status:runner_ok [ row_hold_curr ] in
  let t_hold_curr =
    Masc_tui_keeper_next_run.of_snapshot
      ~freshness:Masc_tui_agenda.Last_read
      ~runner:runner_ok
      ~keeper_name:"alpha"
      snap_hold_curr
  in
  (match t_hold_curr with
   | Masc_tui_keeper_next_run.Held_current ts ->
       Alcotest.(check (float 0.001)) "hold time matches observed_at" hold_observed ts
   | _ -> Alcotest.fail "expected Held_current");
  (match Masc_tui_keeper_next_run.cell ~now t_hold_curr with
   | Some cell ->
       Alcotest.(check bool) "Held_current has Attention tone"
         true (cell.tone = Masc_tui_keeper_axis_cell.Attention);
       Alcotest.(check string) "Held_current text is ◷ 보류"
         "◷ 보류" cell.text
   | None -> Alcotest.fail "expected cell for Held_current");

  (* 5. Held_as_of *)
  let t_hold_as_of =
    Masc_tui_keeper_next_run.of_snapshot
      ~freshness:Masc_tui_agenda.Refresh_needed
      ~runner:runner_ok
      ~keeper_name:"alpha"
      snap_hold_curr
  in
  (match t_hold_as_of with
   | Masc_tui_keeper_next_run.Held_as_of ts ->
       Alcotest.(check (float 0.001)) "hold as of time matches observed_at" hold_observed ts
   | _ -> Alcotest.fail "expected Held_as_of");
  (match Masc_tui_keeper_next_run.cell ~now t_hold_as_of with
   | Some cell ->
       Alcotest.(check bool) "Held_as_of has Quiet tone"
         true (cell.tone = Masc_tui_keeper_axis_cell.Quiet);
       Alcotest.(check bool) "Held_as_of mentions 보류"
         true (String.starts_with ~prefix:"◷ 보류" cell.text)
   | None -> Alcotest.fail "expected cell for Held_as_of");

  (* 6. Not_before *)
  let row_other =
    make_row
      ~id:"sch-other"
      ~status:"scheduled"
      ~due_at_iso:"2026-11-07T12:00:00Z"
      ~keeper_name:"beta"
      ()
  in
  let snap_trunc = make_snapshot ~truncated:true [ row_other ] in
  let t_trunc =
    Masc_tui_keeper_next_run.of_snapshot
      ~freshness:Masc_tui_agenda.Last_read
      ~keeper_name:"alpha"
      snap_trunc
  in
  (match t_trunc with
   | Masc_tui_keeper_next_run.Not_before ts ->
       Alcotest.(check bool) "Not_before has timestamp" true (ts > 0.0)
   | _ -> Alcotest.fail "expected Not_before");
  (match Masc_tui_keeper_next_run.cell ~now t_trunc with
   | Some cell ->
       Alcotest.(check bool) "Not_before has Quiet tone"
         true (cell.tone = Masc_tui_keeper_axis_cell.Quiet);
       Alcotest.(check bool) "Not_before prefix"
         true (String.starts_with ~prefix:"◷ >" cell.text)
   | None -> Alcotest.fail "expected cell for Not_before");

  (* 7. Unknown *)
  let snap_err = make_snapshot ~read_error:"network error" [] in
  let t_err =
    Masc_tui_keeper_next_run.of_snapshot
      ~freshness:Masc_tui_agenda.Last_read
      ~keeper_name:"alpha"
      snap_err
  in
  Alcotest.(check bool) "read error yields Unknown"
    true (t_err = Masc_tui_keeper_next_run.Unknown);
  (match Masc_tui_keeper_next_run.cell ~now t_err with
   | Some cell ->
       Alcotest.(check string) "Unknown cell is ◷ ?" "◷ ?" cell.text;
       Alcotest.(check bool) "Unknown has Quiet tone"
         true (cell.tone = Masc_tui_keeper_axis_cell.Quiet)
   | None -> Alcotest.fail "expected cell for Unknown")
;;

let test_truncation_rule () =
  (* If truncated and last row is inactive (e.g. succeeded), active fleet was exhausted *)
  let row_inactive =
    make_row
      ~id:"sch-done"
      ~status:"succeeded"
      ~due_at_iso:"2026-11-07T08:00:00Z"
      ~keeper_name:"other"
      ()
  in
  let snap_done = make_snapshot ~truncated:true [ row_inactive ] in
  let t =
    Masc_tui_keeper_next_run.of_snapshot
      ~freshness:Masc_tui_agenda.Last_read
      ~keeper_name:"alpha"
      snap_done
  in
  Alcotest.(check bool) "truncated page with inactive tail means No_schedule"
    true (t = Masc_tui_keeper_next_run.No_schedule);

  (* If truncated and last row is active, it indicates Not_before *)
  let row_active =
    make_row
      ~id:"sch-active"
      ~status:"scheduled"
      ~due_at_iso:"2026-11-07T12:00:00Z"
      ~keeper_name:"other"
      ()
  in
  let snap_active = make_snapshot ~truncated:true [ row_active ] in
  let t_active =
    Masc_tui_keeper_next_run.of_snapshot
      ~freshness:Masc_tui_agenda.Last_read
      ~keeper_name:"alpha"
      snap_active
  in
  (match t_active with
   | Masc_tui_keeper_next_run.Not_before _ -> ()
   | _ -> Alcotest.fail "expected Not_before when tail is active")
;;

let test_lane_vs_keeper_separation () =
  (* row with payload_target = lane:triage, payload_keeper_name = alice *)
  let row =
    make_row
      ~id:"sch-lane"
      ~status:"scheduled"
      ~due_at_iso:"2026-11-07T12:00:00Z"
      ~payload_target:"lane:triage"
      ~keeper_name:"alice"
      ()
  in
  let snap = make_snapshot [ row ] in
  let t_alice =
    Masc_tui_keeper_next_run.of_snapshot
      ~freshness:Masc_tui_agenda.Last_read
      ~keeper_name:"alice"
      snap
  in
  (match t_alice with
   | Masc_tui_keeper_next_run.Scheduled_at _ -> ()
   | _ -> Alcotest.fail "alice should match sch_payload_keeper_name");

  (* Querying for 'triage' (lane target) must NOT match *)
  let t_triage =
    Masc_tui_keeper_next_run.of_snapshot
      ~freshness:Masc_tui_agenda.Last_read
      ~keeper_name:"triage"
      snap
  in
  Alcotest.(check bool) "lane target is not a keeper name"
    true (t_triage = Masc_tui_keeper_next_run.No_schedule)
;;

let test_hold_reading_variations () =
  let hold : Masc.Tui_decode.schedule_runner_hold =
    { srh_occurrence_id = "occ-1"
    ; srh_due_at_iso = "2026-11-07T10:00:00Z"
    ; srh_reason = Masc.Tui_decode.Hold_previous_wake_untaken
    ; srh_observed_at = 1794049000.0
    }
  in
  let row =
    make_row
      ~status:"due"
      ~due_at_iso:"2026-11-07T10:00:00Z"
      ~keeper_name:"alpha"
      ~runner_hold:hold
      ()
  in
  let snap = make_snapshot [ row ] in

  (* Stale runner degrades hold to Held_as_of even with Last_read *)
  let runner_stale =
    Masc.Tui_decode.Runner_status Schedule_contract_values.Runner_stale
  in
  let t_stale =
    Masc_tui_keeper_next_run.of_snapshot
      ~freshness:Masc_tui_agenda.Last_read
      ~runner:runner_stale
      ~keeper_name:"alpha"
      snap
  in
  (match t_stale with
   | Masc_tui_keeper_next_run.Held_as_of _ -> ()
   | _ -> Alcotest.fail "stale runner must yield Held_as_of")
;;

let test_index_of_agenda () =
  let row1 =
    make_row
      ~id:"sch-1"
      ~status:"scheduled"
      ~due_at_iso:"2026-11-07T12:00:00Z"
      ~keeper_name:"alpha"
      ()
  in
  let row2 =
    make_row
      ~id:"sch-2"
      ~status:"due"
      ~due_at_iso:"2026-11-07T09:00:00Z"
      ~keeper_name:"beta"
      ()
  in
  let snap = make_snapshot [ row1; row2 ] in
  let index =
    Masc_tui_keeper_next_run.index_of_agenda
      ~freshness:Masc_tui_agenda.Last_read
      (Some snap)
  in
  (match Masc_tui_keeper_next_run.find index ~keeper_name:"alpha" with
   | Masc_tui_keeper_next_run.Scheduled_at _ -> ()
   | _ -> Alcotest.fail "alpha in index should be Scheduled_at");
  (match Masc_tui_keeper_next_run.find index ~keeper_name:"beta" with
   | Masc_tui_keeper_next_run.Late_since _ -> ()
   | _ -> Alcotest.fail "beta in index should be Late_since");
  Alcotest.(check bool) "unknown keeper in index yields No_schedule"
    true (Masc_tui_keeper_next_run.find index ~keeper_name:"gamma" = Masc_tui_keeper_next_run.No_schedule);

  (* None snapshot yields Unknown *)
  let empty_index =
    Masc_tui_keeper_next_run.index_of_agenda
      ~freshness:Masc_tui_agenda.Last_read
      None
  in
  Alcotest.(check bool) "None snapshot index yields Unknown"
    true (Masc_tui_keeper_next_run.find empty_index ~keeper_name:"alpha" = Masc_tui_keeper_next_run.Unknown)
;;


(* {1 The strip ahead} (RFC-0515 V7)

   Every case reads the strip at 11:15 UTC, so its first hour is 11:00-12:00
   and only what is still ahead of 11:15 counts in it. The last hour is
   22:00-23:00. *)

module Next_run = Masc_tui_keeper_next_run

let strip_now = 1794050100.0 (* 2026-11-07T11:15:00Z *)

let hour_text = function
  | Next_run.Hour_quiet -> "quiet"
  | Next_run.Hour_wakes n -> Printf.sprintf "wakes %d" n
  | Next_run.Hour_wakes_at_least n -> Printf.sprintf "at least %d" n
  | Next_run.Hour_unknown -> "unknown"
;;

let hour = Alcotest.testable (fun fmt h -> Format.pp_print_string fmt (hour_text h)) ( = )

(* The strip, hour by hour, from one value per position. *)
let strip_of hour_at = Some (List.init Masc_tui_keeper_mark.pulse_hours hour_at)

let check_strip name expected ?(now = strip_now) ?(keeper_name = "alpha") snapshot =
  Alcotest.(check (option (list hour)))
    name expected
    (Next_run.hours_of_snapshot ~now ~keeper_name snapshot)
;;

let scheduled_row ?(keeper_name = "alpha") ?id ?expires_at_iso ?runner_hold ~due ~recurrence () =
  make_row ?id ~status:"scheduled" ~due_at_iso:due ~next_due_at_iso:due ~keeper_name
    ?expires_at_iso ?runner_hold ~recurrence ()
;;

let test_strip_counts_each_recurrence () =
  let strip recurrence due = Some (make_snapshot [ scheduled_row ~due ~recurrence () ]) in
  check_strip "an interval of 600 s wakes six times an hour; 11:20 to 11:50 are still ahead"
    (strip_of (function 0 -> Next_run.Hour_wakes 4 | _ -> Next_run.Hour_wakes 6))
    (strip (Ok (Schedule_domain.Interval { interval_sec = 600 })) "2026-11-07T11:20:00Z");
  check_strip "an interval of 25 min falls across hour edges: 11:20 11:45 | 12:10 12:35 | 13:00 ..."
    (strip_of (function
       | 0 | 1 | 3 | 5 | 6 | 8 | 10 | 11 -> Next_run.Hour_wakes 2
       | _ -> Next_run.Hour_wakes 3))
    (strip (Ok (Schedule_domain.Interval { interval_sec = 1500 })) "2026-11-07T11:20:00Z");
  check_strip "a daily run wakes once, in its own hour"
    (strip_of (function 4 -> Next_run.Hour_wakes 1 | _ -> Next_run.Hour_quiet))
    (strip
       (Ok (Schedule_domain.Daily { hour = 15; minute = 0; second = 0; timezone = "UTC" }))
       "2026-11-07T15:00:00Z");
  check_strip "a cron on every half hour wakes twice an hour; 11:30 is still ahead"
    (strip_of (function 0 -> Next_run.Hour_wakes 1 | _ -> Next_run.Hour_wakes 2))
    (strip
       (Ok (Schedule_domain.Cron { expression = "*/30 * * * *"; timezone = "UTC" }))
       "2026-11-07T11:30:00Z");
  check_strip "a one-shot wakes once"
    (strip_of (function 2 -> Next_run.Hour_wakes 1 | _ -> Next_run.Hour_quiet))
    (strip (Ok Schedule_domain.One_shot) "2026-11-07T13:45:00Z")
;;

let test_strip_stops_at_the_expiry () =
  check_strip "nothing wakes at or after 13:00"
    (strip_of (function
       | 0 -> Next_run.Hour_wakes 4
       | 1 -> Next_run.Hour_wakes 6
       | _ -> Next_run.Hour_quiet))
    (Some
       (make_snapshot
          [ scheduled_row ~due:"2026-11-07T11:20:00Z" ~expires_at_iso:"2026-11-07T13:00:00Z"
              ~recurrence:(Ok (Schedule_domain.Interval { interval_sec = 600 }))
              ()
          ]))
;;

let test_strip_leaves_out_a_held_row () =
  let hold : Masc.Tui_decode.schedule_runner_hold =
    { srh_occurrence_id = "occ-1"
    ; srh_due_at_iso = "2026-11-07T11:00:00Z"
    ; srh_reason = Masc.Tui_decode.Hold_previous_wake_untaken
    ; srh_observed_at = strip_now
    }
  in
  check_strip "a held interval draws no wake; the one-shot beside it still does"
    (strip_of (function 2 -> Next_run.Hour_wakes 1 | _ -> Next_run.Hour_quiet))
    (Some
       (make_snapshot
          [ scheduled_row ~id:"held" ~due:"2026-11-07T11:20:00Z" ~runner_hold:hold
              ~recurrence:(Ok (Schedule_domain.Interval { interval_sec = 600 }))
              ()
          ; scheduled_row ~id:"once" ~due:"2026-11-07T13:45:00Z"
              ~recurrence:(Ok Schedule_domain.One_shot) ()
          ]))
;;

let test_strip_after_an_unread_recurrence_is_unknown () =
  check_strip "the due time wakes; every hour from it on may hold more"
    (strip_of (function
       | 0 | 1 -> Next_run.Hour_quiet
       | 2 -> Next_run.Hour_wakes_at_least 1
       | _ -> Next_run.Hour_unknown))
    (Some
       (make_snapshot
          [ scheduled_row ~due:"2026-11-07T13:45:00Z"
              ~recurrence:(Error "unknown recurrence kind: weekly") ()
          ]))
;;

let test_strip_of_an_unread_agenda_is_unknown () =
  let unknown = strip_of (fun _ -> Next_run.Hour_unknown) in
  check_strip "no agenda read yet" unknown None;
  check_strip "an agenda read that failed" unknown
    (Some (make_snapshot ~read_error:"store unreadable" []));
  check_strip "a keeper with no schedule has no strip" None (Some (make_snapshot []))
;;

(* The page is cut after beta's 14:20 run. A row past the page is due no
   earlier than that, so the hours before it are known and the hours from it
   on are not, for every keeper. *)
let test_strip_of_a_cut_page_ends_at_its_last_row () =
  let snapshot =
    Some
      (make_snapshot ~truncated:true
         [ scheduled_row ~id:"alpha-hourly" ~due:"2026-11-07T11:30:00Z"
             ~recurrence:(Ok (Schedule_domain.Interval { interval_sec = 3600 }))
             ()
         ; scheduled_row ~keeper_name:"beta" ~id:"beta-once" ~due:"2026-11-07T14:20:00Z"
             ~recurrence:(Ok Schedule_domain.One_shot) ()
         ])
  in
  check_strip "alpha's hourly wakes are known; from 14:00 there may be more"
    (strip_of (function
       | 0 | 1 | 2 -> Next_run.Hour_wakes 1
       | _ -> Next_run.Hour_wakes_at_least 1))
    snapshot;
  check_strip "beta's run is the cut; after it nothing is known" ~keeper_name:"beta"
    (strip_of (function
       | 0 | 1 | 2 -> Next_run.Hour_quiet
       | 3 -> Next_run.Hour_wakes_at_least 1
       | _ -> Next_run.Hour_unknown))
    snapshot;
  check_strip "a keeper with no row on the page is quiet until the cut" ~keeper_name:"gamma"
    (strip_of (function 0 | 1 | 2 -> Next_run.Hour_quiet | _ -> Next_run.Hour_unknown))
    snapshot
;;

(* The strip says whether an hour wakes the keeper, not how many times. *)
let test_strip_marks_say_whether_an_hour_wakes () =
  Alcotest.(check string) "a wake draws one mark however sure its count"
    (Next_run.hour_mark (Next_run.Hour_wakes 2))
    (Next_run.hour_mark (Next_run.Hour_wakes_at_least 1));
  Alcotest.(check int) "quiet, wake and unknown hours draw three marks" 3
    (List.length
       (List.sort_uniq String.compare
          (List.map Next_run.hour_mark
             [ Next_run.Hour_quiet; Next_run.Hour_wakes 1; Next_run.Hour_unknown ])))
;;

(* The index keeps each keeper's wakes for the clock hour it was asked in.
   Asked again later in that hour, or in the next one, it answers what the
   snapshot answers at that time. *)
let test_index_strip_follows_the_clock () =
  let snapshot =
    Some
      (make_snapshot
         [ scheduled_row ~due:"2026-11-07T11:20:00Z"
             ~recurrence:(Ok (Schedule_domain.Cron { expression = "*/10 * * * *"; timezone = "UTC" }))
             ()
         ])
  in
  let index = Next_run.index_of_agenda ~freshness:Masc_tui_agenda.Last_read snapshot in
  List.iter
    (fun (name, now) ->
      Alcotest.(check (option (list hour)))
        name
        (Next_run.hours_of_snapshot ~now ~keeper_name:"alpha" snapshot)
        (Next_run.find_hours index ~now ~keeper_name:"alpha"))
    [ "first asked at 11:15", strip_now
    ; "11:35, the same hour", strip_now +. 1200.
    ; "12:05, the next hour", strip_now +. 3000.
    ]
;;

let () =
  Alcotest.run "tui_keeper_next_run"
    [ ( "next_run reduction"
      , [ Alcotest.test_case "seven branches" `Quick test_seven_branches
        ; Alcotest.test_case "truncation rule" `Quick test_truncation_rule
        ; Alcotest.test_case "lane vs keeper separation" `Quick test_lane_vs_keeper_separation
        ; Alcotest.test_case "hold reading variations" `Quick test_hold_reading_variations
        ; Alcotest.test_case "index of agenda" `Quick test_index_of_agenda
        ] )
    ; ( "strip ahead"
      , [ Alcotest.test_case "each recurrence" `Quick test_strip_counts_each_recurrence
        ; Alcotest.test_case "expiry" `Quick test_strip_stops_at_the_expiry
        ; Alcotest.test_case "held row" `Quick test_strip_leaves_out_a_held_row
        ; Alcotest.test_case "unread recurrence" `Quick test_strip_after_an_unread_recurrence_is_unknown
        ; Alcotest.test_case "unread agenda" `Quick test_strip_of_an_unread_agenda_is_unknown
        ; Alcotest.test_case "cut page" `Quick test_strip_of_a_cut_page_ends_at_its_last_row
        ; Alcotest.test_case "index follows the clock" `Quick test_index_strip_follows_the_clock
        ; Alcotest.test_case "marks" `Quick test_strip_marks_say_whether_an_hour_wakes
        ] )
    ]
