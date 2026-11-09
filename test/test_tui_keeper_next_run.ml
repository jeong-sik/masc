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

(* Wake strip (RFC-0515 §2.4.4). [day] starts on a slot boundary and [now] is
   one minute into it, so slot [i] holds [day + i * 30min]. *)
let day = 1794009600.0 (* 2026-11-07T00:00:00Z *)
let now = day +. 60.
let ahead = 24
let iso ~h ~m = Printf.sprintf "2026-11-07T%02d:%02d:00Z" h m

let scheduled ?(keeper_name = "alpha") ?expires_at_iso ?recurrence ~h ~m () =
  make_row ~keeper_name ~due_at_iso:(iso ~h ~m) ?expires_at_iso ?recurrence ()
;;

let agenda_index snapshot =
  Masc_tui_keeper_next_run.index_of_agenda ~freshness:Masc_tui_agenda.Last_read snapshot
;;

let strip_of ?(keeper_name = "alpha") rows =
  Masc_tui_keeper_next_run.wake_strip
    (agenda_index (Some (make_snapshot rows)))
    ~now ~ahead ~keeper_name
;;

let wake_slot =
  Alcotest.testable
    (fun fmt -> function
       | Masc_tui_keeper_next_run.Wakes n -> Format.fprintf fmt "Wakes %d" n
       | Masc_tui_keeper_next_run.Wakes_unknown -> Format.pp_print_string fmt "Wakes_unknown")
    ( = )
;;

let strip = Alcotest.list wake_slot
let every slot = List.init (ahead + 1) (fun _ -> slot)

(* [Wakes 1] in the listed slots, [Wakes 0] elsewhere. *)
let once_in indexes =
  List.init (ahead + 1) (fun index ->
    Masc_tui_keeper_next_run.Wakes (if List.mem index indexes then 1 else 0))
;;

let interval seconds = Ok (Schedule_domain.Interval { interval_sec = seconds })

let test_interval_wakes_every_period () =
  (* 00:00 is a minute behind [now] and not late, so it is in the now slot. *)
  Alcotest.check strip "600 s puts three wakes in every slot"
    (every (Masc_tui_keeper_next_run.Wakes 3))
    (strip_of [ scheduled ~h:0 ~m:0 ~recurrence:(interval 600) () ])
;;

(* A due before the now slot and not late: the runner fires it once, so the
   occurrences between it and the slot start are not counted. An occurrence
   on the slot start, 00:00, counts in the now slot beside the missed due. *)
let test_an_occurrence_on_the_slot_start_counts () =
  let missed ~due_at_iso recurrence =
    strip_of [ make_row ~keeper_name:"alpha" ~due_at_iso ~recurrence () ]
  in
  let hourly =
    List.init (ahead + 1) (fun index ->
      Masc_tui_keeper_next_run.Wakes
        (if index = 0 then 2 else if index mod 2 = 0 then 1 else 0))
  in
  Alcotest.check strip "interval: 21:00 missed, then 00:00 and every hour" hourly
    (missed ~due_at_iso:"2026-11-06T21:00:00Z" (interval 3600));
  Alcotest.check strip "cron: 21:00 missed, then 00:00 and every hour" hourly
    (missed ~due_at_iso:"2026-11-06T21:00:00Z"
       (Ok (Schedule_domain.Cron { expression = "0 * * * *"; timezone = "UTC" })));
  Alcotest.check strip "daily: yesterday's 00:00 missed, then today's 00:00"
    (List.init (ahead + 1) (fun index ->
       Masc_tui_keeper_next_run.Wakes (if index = 0 then 2 else 0)))
    (missed ~due_at_iso:"2026-11-06T00:00:00Z"
       (Ok (Schedule_domain.Daily { hour = 0; minute = 0; second = 0; timezone = "UTC" })))
;;

let test_strip_is_the_same_for_every_now_in_one_slot () =
  (* At 00:20 the occurrence at 00:10 has passed. It is in the now slot all
     the same, so the strip read at 00:01 and at 00:20 agree. *)
  let index =
    agenda_index (Some (make_snapshot [ scheduled ~h:0 ~m:0 ~recurrence:(interval 600) () ]))
  in
  let read now = Masc_tui_keeper_next_run.wake_strip index ~now ~ahead ~keeper_name:"alpha" in
  let early = read (day +. 60.) in
  let late = read (day +. 1200.) in
  Alcotest.check strip "00:01 reads three wakes a slot"
    (every (Masc_tui_keeper_next_run.Wakes 3)) early;
  Alcotest.check strip "00:20 reads the same strip" early late;
  Alcotest.check strip "a fresh index at 00:20 agrees"
    early
    (Masc_tui_keeper_next_run.wake_strip
       (agenda_index (Some (make_snapshot [ scheduled ~h:0 ~m:0 ~recurrence:(interval 600) () ])))
       ~now:(day +. 1200.) ~ahead ~keeper_name:"alpha")
;;

let test_daily_wakes_once () =
  let daily =
    Ok (Schedule_domain.Daily { hour = 3; minute = 0; second = 0; timezone = "UTC" })
  in
  Alcotest.check strip "03:00 is the only wake in the next 12.5 hours"
    (once_in [ 6 ])
    (strip_of [ scheduled ~h:3 ~m:0 ~recurrence:daily () ])
;;

let test_cron_every_half_hour () =
  let cron = Ok (Schedule_domain.Cron { expression = "*/30 * * * *"; timezone = "UTC" }) in
  Alcotest.check strip "*/30 puts one wake in every slot"
    (every (Masc_tui_keeper_next_run.Wakes 1))
    (strip_of [ scheduled ~h:0 ~m:0 ~recurrence:cron () ])
;;

let test_one_shot_wakes_once () =
  Alcotest.check strip "a one-shot at 05:00 is one wake"
    (once_in [ 10 ])
    (strip_of [ scheduled ~h:5 ~m:0 () ])
;;

let test_no_wake_at_or_after_expiry () =
  let row =
    scheduled ~h:0 ~m:0 ~recurrence:(interval 600) ~expires_at_iso:(iso ~h:1 ~m:0) ()
  in
  Alcotest.check strip "wakes stop at 01:00"
    (List.init (ahead + 1) (fun index ->
       Masc_tui_keeper_next_run.Wakes (if index < 2 then 3 else 0)))
    (strip_of [ row ])
;;

let test_held_and_late_rows_are_not_on_the_strip () =
  let hold : Masc.Tui_decode.schedule_runner_hold =
    { srh_occurrence_id = "occ-1"
    ; srh_due_at_iso = iso ~h:1 ~m:0
    ; srh_reason = Masc.Tui_decode.Hold_previous_wake_untaken
    ; srh_observed_at = now
    }
  in
  let held = { (scheduled ~h:1 ~m:0 ()) with sch_runner_hold = Some hold } in
  let late = make_row ~id:"sch-late" ~status:"due" ~keeper_name:"alpha"
      ~due_at_iso:(iso ~h:0 ~m:0) ~recurrence:(interval 600) () in
  Alcotest.check strip "a held row and a late row add nothing"
    (every (Masc_tui_keeper_next_run.Wakes 0))
    (strip_of [ held; late ]);
  Alcotest.check strip "the same row without the hold wakes"
    (once_in [ 2 ])
    (strip_of [ { held with sch_runner_hold = None } ])
;;

let test_unread_recurrence_knows_only_the_first_wake () =
  Alcotest.check strip "after 01:00 the slots are unknown"
    (List.init (ahead + 1) (fun index ->
       if index < 2 then Masc_tui_keeper_next_run.Wakes 0
       else if index = 2 then Masc_tui_keeper_next_run.Wakes 1
       else Masc_tui_keeper_next_run.Wakes_unknown))
    (strip_of [ scheduled ~h:1 ~m:0 ~recurrence:(Error "unknown recurrence kind") () ])
;;

let test_failed_or_missing_agenda_is_unknown () =
  let unknown = every Masc_tui_keeper_next_run.Wakes_unknown in
  Alcotest.check strip "a failed read"
    unknown
    (Masc_tui_keeper_next_run.wake_strip
       (agenda_index (Some (make_snapshot ~read_error:"store unreadable" [])))
       ~now ~ahead ~keeper_name:"alpha");
  Alcotest.check strip "no agenda yet"
    unknown
    (Masc_tui_keeper_next_run.wake_strip (agenda_index None) ~now ~ahead ~keeper_name:"alpha")
;;

let test_cut_agenda_is_unknown_from_its_last_due () =
  let mine = scheduled ~h:1 ~m:0 () in
  let last = make_row ~id:"sch-other" ~keeper_name:"beta" ~due_at_iso:(iso ~h:4 ~m:0) () in
  let read rows =
    Masc_tui_keeper_next_run.wake_strip
      (agenda_index (Some (make_snapshot ~truncated:true rows)))
      ~now ~ahead ~keeper_name:"alpha"
  in
  Alcotest.check strip "slots before 04:00 are known, from 04:00 on unknown"
    (List.init (ahead + 1) (fun index ->
       if index = 2 then Masc_tui_keeper_next_run.Wakes 1
       else if index < 8 then Masc_tui_keeper_next_run.Wakes 0
       else Masc_tui_keeper_next_run.Wakes_unknown))
    (read [ mine; last ]);
  Alcotest.check strip "a closed last row means every active row was sent"
    (once_in [ 2 ])
    (read [ mine; { last with sch_status = "succeeded" } ])
;;

let test_strip_follows_the_now_slot_and_length () =
  let index = agenda_index (Some (make_snapshot [ scheduled ~h:1 ~m:0 () ])) in
  let read ~now ~ahead =
    Masc_tui_keeper_next_run.wake_strip index ~now ~ahead ~keeper_name:"alpha"
  in
  Alcotest.check strip "three slots" (Masc_tui_keeper_next_run.[ Wakes 0; Wakes 0; Wakes 1 ])
    (read ~now ~ahead:2);
  Alcotest.check strip "five slots"
    (Masc_tui_keeper_next_run.[ Wakes 0; Wakes 0; Wakes 1; Wakes 0; Wakes 0 ])
    (read ~now ~ahead:4);
  Alcotest.check strip "half an hour later the wake is one slot nearer"
    (Masc_tui_keeper_next_run.[ Wakes 0; Wakes 1; Wakes 0 ])
    (read ~now:(now +. 1800.) ~ahead:2)
;;

let test_sum_rule () =
  let open Masc_tui_keeper_next_run in
  Alcotest.check strip "known wakes add; a zero with an unknown is unknown"
    [ Wakes_unknown; Wakes_unknown; Wakes 3; Wakes 1; Wakes 0 ]
    (sum_wake_strips
       [ [ Wakes 0; Wakes_unknown; Wakes 2; Wakes_unknown; Wakes 0 ]
       ; [ Wakes_unknown; Wakes_unknown; Wakes_unknown; Wakes 1; Wakes 0 ]
       ; [ Wakes 0; Wakes 0; Wakes 1 ]
       ])
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
    ; ( "wake strip"
      , [ Alcotest.test_case "interval" `Quick test_interval_wakes_every_period
        ; Alcotest.test_case "occurrence on the slot start" `Quick
            test_an_occurrence_on_the_slot_start_counts
        ; Alcotest.test_case "same strip within one slot" `Quick
            test_strip_is_the_same_for_every_now_in_one_slot
        ; Alcotest.test_case "daily" `Quick test_daily_wakes_once
        ; Alcotest.test_case "cron" `Quick test_cron_every_half_hour
        ; Alcotest.test_case "one-shot" `Quick test_one_shot_wakes_once
        ; Alcotest.test_case "expiry" `Quick test_no_wake_at_or_after_expiry
        ; Alcotest.test_case "held and late" `Quick
            test_held_and_late_rows_are_not_on_the_strip
        ; Alcotest.test_case "unread recurrence" `Quick
            test_unread_recurrence_knows_only_the_first_wake
        ; Alcotest.test_case "failed or missing agenda" `Quick
            test_failed_or_missing_agenda_is_unknown
        ; Alcotest.test_case "cut agenda" `Quick test_cut_agenda_is_unknown_from_its_last_due
        ; Alcotest.test_case "now slot and length" `Quick
            test_strip_follows_the_now_slot_and_length
        ; Alcotest.test_case "sum rule" `Quick test_sum_rule
        ] )
    ]
