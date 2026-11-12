let make_librarian
    ?state
    ?admission_wait
    ?unread_atom_turns
    ?unread_official_turns
    ?stalled
    ?last_success_at
    () : Masc.Tui_decode_memory_health.memory_librarian_health =
  { mlh_state = state
  ; mlh_admission_wait = admission_wait
  ; mlh_operator_action_required = Masc.Keeper_librarian_pending.attention_required
      ~durable:(Option.bind state (function
        | Masc.Tui_decode_memory_health.Pass_pending pending -> Some pending
        | Pass_off | Pass_lane_unconfigured | Pass_drained | Pass_yielded_to_waiting_unit
        | Pass_not_committed | Pass_stopped _ | Pass_raised _ -> None))
      ~admission:admission_wait
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
    ?(keeper_id = "alpha")
    ?(added = 1)
    ?(removed = 0)
    ?(source_invalidations = 0)
    ?updated_at
    ?age_bins
    librarian : Masc.Tui_decode_memory_health.memory_keeper_health =
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
  ; mkh_facts_by_hour = []
  ; mkh_changes_since_start = []
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

let make_snapshot ?(refusals = []) keepers : Masc.Tui_decode_memory_health.memory_health_snapshot =
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
  ; mhs_total_source_snapshot_bytes = 0
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
  ; mhs_librarian_attention_required_keepers = 0
  }
;;

let test_lag_rules () =
  let lib_measured =
    make_librarian ~unread_atom_turns:5 ~unread_official_turns:3 ()
  in
  Alcotest.(check (option int)) "lag is sum when both present"
    (Some 8) (Masc_tui_keeper_memory_reading.unread_lag lib_measured);

  let lib_unmeasured =
    make_librarian ~unread_atom_turns:5 ()
  in
  Alcotest.(check (option int)) "lag is None when one missing"
    None (Masc_tui_keeper_memory_reading.unread_lag lib_unmeasured);

  let snap =
    make_snapshot
      [ make_keeper_health ~keeper_id:"alpha" lib_measured
      ; make_keeper_health ~keeper_id:"beta" lib_unmeasured
      ]
  in
  let idx = Masc_tui_keeper_memory_reading.index_of_snapshot (Some snap) in
  (match Masc_tui_keeper_memory_reading.find idx ~keeper_name:"alpha" with
   | Masc_tui_keeper_memory_reading.Row { lag = Masc_tui_keeper_memory_reading.Lag 8; _ } -> ()
   | _ -> Alcotest.fail "alpha should have Lag 8");
  (match Masc_tui_keeper_memory_reading.find idx ~keeper_name:"beta" with
   | Masc_tui_keeper_memory_reading.Row { lag = Masc_tui_keeper_memory_reading.Lag_unmeasured; _ } -> ()
   | _ -> Alcotest.fail "beta should have Lag_unmeasured")
;;

let test_row_carries_the_servers_age_ladder () =
  let lib = make_librarian ~unread_atom_turns:0 ~unread_official_turns:0 () in
  let bins = Masc.Keeper_memory_age_bins.of_first_seen ~now:7200.0 [ 0.0; 3600.0; 7200.0 ] in
  let snap =
    make_snapshot
      [ make_keeper_health ~keeper_id:"alpha" ~age_bins:bins lib
      ; make_keeper_health ~keeper_id:"beta" lib
      ]
  in
  let idx = Masc_tui_keeper_memory_reading.index_of_snapshot (Some snap) in
  (match Masc_tui_keeper_memory_reading.find idx ~keeper_name:"alpha" with
   | Masc_tui_keeper_memory_reading.Row { age_bins = Some carried; _ } ->
     Alcotest.(check bool) "alpha carries the bins the server counted" true (carried = bins)
   | Masc_tui_keeper_memory_reading.Row { age_bins = None; _ }
   | Masc_tui_keeper_memory_reading.Unknown
   | Masc_tui_keeper_memory_reading.No_row
   | Masc_tui_keeper_memory_reading.Refused _ ->
     Alcotest.fail "alpha should carry its ladder");
  (match Masc_tui_keeper_memory_reading.find idx ~keeper_name:"beta" with
   | Masc_tui_keeper_memory_reading.Row { age_bins = None; _ } -> ()
   | Masc_tui_keeper_memory_reading.Row { age_bins = Some _; _ }
   | Masc_tui_keeper_memory_reading.Unknown
   | Masc_tui_keeper_memory_reading.No_row
   | Masc_tui_keeper_memory_reading.Refused _ ->
     Alcotest.fail "beta has no ladder, which is not a ladder of zeros")
;;

let test_no_row_vs_unknown_vs_refused () =
  let lib = make_librarian ~unread_atom_turns:0 ~unread_official_turns:0 () in
  let k = make_keeper_health ~keeper_id:"alpha" lib in

  (* Clean snapshot: alpha exists, beta does not -> No_row *)
  let snap_clean = make_snapshot [ k ] in
  let idx_clean = Masc_tui_keeper_memory_reading.index_of_snapshot (Some snap_clean) in
  Alcotest.(check bool) "missing keeper is No_row"
    true (Masc_tui_keeper_memory_reading.find idx_clean ~keeper_name:"beta" = Masc_tui_keeper_memory_reading.No_row);

  (* Refused keeper with explicit ID *)
  let refusal_named : Masc.Tui_decode_memory_health.memory_keeper_refusal =
    { mkr_keeper_id = Some "gamma"; mkr_reason = "corrupt snapshot" }
  in
  let snap_named = make_snapshot ~refusals:[ refusal_named ] [ k ] in
  let idx_named = Masc_tui_keeper_memory_reading.index_of_snapshot (Some snap_named) in
  Alcotest.(check bool) "gamma is Refused"
    true (Masc_tui_keeper_memory_reading.find idx_named ~keeper_name:"gamma" = Masc_tui_keeper_memory_reading.Refused "corrupt snapshot");

  (* Anonymous refusal makes unlisted keepers Unknown *)
  let refusal_anon : Masc.Tui_decode_memory_health.memory_keeper_refusal =
    { mkr_keeper_id = None; mkr_reason = "parse error" }
  in
  let snap_anon = make_snapshot ~refusals:[ refusal_anon ] [ k ] in
  let idx_anon = Masc_tui_keeper_memory_reading.index_of_snapshot (Some snap_anon) in
  Alcotest.(check bool) "alpha is still found"
    true (match Masc_tui_keeper_memory_reading.find idx_anon ~keeper_name:"alpha" with
          | Masc_tui_keeper_memory_reading.Row _ -> true | _ -> false);
  Alcotest.(check bool) "unlisted keeper is Unknown when anonymous refusal exists"
    true (Masc_tui_keeper_memory_reading.find idx_anon ~keeper_name:"beta" = Masc_tui_keeper_memory_reading.Unknown);

  (* None snapshot yields Unknown *)
  let idx_none = Masc_tui_keeper_memory_reading.index_of_snapshot None in
  Alcotest.(check bool) "None snapshot yields Unknown"
    true (Masc_tui_keeper_memory_reading.find idx_none ~keeper_name:"alpha" = Masc_tui_keeper_memory_reading.Unknown)
;;

let test_cells_formatting () =
  let now = 1794050000.0 in
  let updated_at = 1794047180.0 in (* 47m ago *)
  let stalled : Masc.Tui_decode_memory_health.memory_librarian_stalled =
    Masc.Tui_decode_memory_health.Stalled_gap { mls_gap_start_atom = 10; mls_gap_end_atom = 15 }
  in
  let lib =
    make_librarian
      ~unread_atom_turns:2
      ~unread_official_turns:1
      ~stalled
      ()
  in
  let k =
    make_keeper_health
      ~keeper_id:"alpha"
      ~added:1
      ~removed:0
      ~source_invalidations:2
      ~updated_at
      lib
  in
  let snap = make_snapshot [ k ] in
  let idx = Masc_tui_keeper_memory_reading.index_of_snapshot (Some snap) in
  let reading = Masc_tui_keeper_memory_reading.find idx ~keeper_name:"alpha" in
  let cells = Masc_tui_keeper_memory_reading.cells ~now reading in
  Alcotest.(check int) "produces 4 cells (gap, lag, clock, stale)" 4 (List.length cells);
  Alcotest.(check string) "first cell is gap 5" "gap 5" (List.nth cells 0).text;
  Alcotest.(check string) "second cell is lag 3" "lag 3" (List.nth cells 1).text;
  Alcotest.(check string) "third cell is the clock +47m00s +1 -0" "+47m00s +1 -0"
    (List.nth cells 2).text;
  Alcotest.(check string) "fourth cell is stale ×2" "stale ×2" (List.nth cells 3).text
;;

module Reading = Masc_tui_keeper_memory_reading
module Health = Masc.Tui_decode_memory_health
module Cell = Masc_tui_keeper_axis_cell

let field_label = function
  | Reading.Measured _ -> "measured"
  | Reading.Unmeasured -> "unmeasured"
  | Reading.No_snapshot -> "no snapshot"
  | Reading.Snapshot_unknown -> "snapshot unknown"
  | Reading.Row_absent -> "row absent"
  | Reading.Row_refused -> "row refused"

let check_field name expected actual =
  Alcotest.(check string) name (field_label expected) (field_label actual);
  Alcotest.(check bool) (name ^ ": same value") true (expected = actual)

let bins = Masc.Keeper_memory_age_bins.of_first_seen ~now:7200.0 [ 0.0; 3600.0; 7200.0 ]

let reading_of keepers ?(refusals = []) keeper_name =
  Reading.find
    (Reading.index_of_snapshot (Some (make_snapshot ~refusals keepers)))
    ~keeper_name

let test_a_reading_gives_its_value_or_why_it_has_none () =
  let measured =
    make_keeper_health ~keeper_id:"alpha" ~updated_at:1794040000.0 ~age_bins:bins
      (make_librarian ~state:(Health.Pass_pending (Masc.Keeper_librarian_pending.Publication { request_id = "fixture-original"; detail = "publication is unfinished" })) ~last_success_at:1794030000.0 ())
  in
  let unmeasured = make_keeper_health ~keeper_id:"beta" (make_librarian ()) in
  let alpha = reading_of [ measured; unmeasured ] "alpha" in
  let beta = reading_of [ measured; unmeasured ] "beta" in
  check_field "the pass end comes from the row's librarian" (Reading.Measured (Health.Pass_pending (Masc.Keeper_librarian_pending.Publication { request_id = "fixture-original"; detail = "publication is unfinished" })))
    (Reading.pass_end alpha);
  check_field "the digest time comes from the row's librarian" (Reading.Measured 1794030000.0)
    (Reading.digest_at alpha);
  check_field "the update time comes from the row" (Reading.Measured 1794040000.0)
    (Reading.updated_at alpha);
  check_field "the age bins come from the row" (Reading.Measured bins) (Reading.age_bins alpha);
  check_field "a pass the server did not measure" Reading.Unmeasured (Reading.pass_end beta);
  check_field "a digest the server did not measure" Reading.Unmeasured (Reading.digest_at beta);
  check_field "a row without an update has no snapshot" Reading.No_snapshot
    (Reading.updated_at beta);
  check_field "a ladder the server did not count" Reading.Unmeasured (Reading.age_bins beta)

let test_a_reading_without_a_row_names_why_in_every_field () =
  let refusal : Health.memory_keeper_refusal =
    { mkr_keeper_id = Some "gamma"; mkr_reason = "corrupt snapshot" }
  in
  let refused = reading_of ~refusals:[ refusal ] [] "gamma" in
  let absent = reading_of [] "delta" in
  let unknown = Reading.find (Reading.index_of_snapshot None) ~keeper_name:"alpha" in
  (* Each field has its own value type, so the expected reason is its label. *)
  List.iter
    (fun (name, reading, expected) ->
      let check field actual =
        Alcotest.(check string) (name ^ ": " ^ field) (field_label expected) actual
      in
      check "pass" (field_label (Reading.pass_end reading));
      check "digest" (field_label (Reading.digest_at reading));
      check "update" (field_label (Reading.updated_at reading));
      check "ages" (field_label (Reading.age_bins reading)))
    [ "no snapshot read", unknown, (Reading.Snapshot_unknown : unit Reading.field)
    ; "no row", absent, Reading.Row_absent
    ; "a refused row", refused, Reading.Row_refused
    ]

let test_the_pass_cell_tone_follows_how_the_pass_ended () =
  let tone_of state =
    (Reading.pass_cell
       (reading_of [ make_keeper_health ~keeper_id:"alpha" (make_librarian ?state ()) ] "alpha"))
      .tone
  in
  let check name expected state = Alcotest.(check bool) name true (expected = tone_of state) in
  check "a stopped pass is a failure" Cell.Failure (Some (Health.Pass_stopped "lane gone"));
  check "a crashed pass is a failure" Cell.Failure (Some (Health.Pass_raised "exception"));
  check "a pass that saved nothing asks for attention" Cell.Attention
    (Some Health.Pass_not_committed);
  check "a librarian with no lane asks for attention" Cell.Attention
    (Some Health.Pass_lane_unconfigured);
  check "a caught-up pass is quiet" Cell.Quiet (Some Health.Pass_drained);
  check "a pending pass is quiet" Cell.Quiet (Some (Health.Pass_pending (Masc.Keeper_librarian_pending.Publication { request_id = "fixture-original"; detail = "publication is unfinished" })));
  List.iter (fun (wait, tone) ->
    let pending = Masc.Keeper_librarian_pending.Worker {
      installation_id = "librarian"; request_id = "original"; wait } in
    let state = Health.Pass_pending pending in
    check "worker wait attention follows its execution evidence" tone (Some state))
    Masc.Keeper_librarian_pending.[
      Capacity, Cell.Quiet;
      Processing, Cell.Quiet;
      Outcome_unknown, Cell.Attention;
      Unreachable, Cell.Quiet;
      Missing_after_dispatch, Cell.Attention;
      Journal_recheck, Cell.Quiet;
    ];
  check "a pass that yielded to waiting work is quiet" Cell.Quiet
    (Some Health.Pass_yielded_to_waiting_unit);
  check "a librarian switched off is quiet" Cell.Quiet (Some Health.Pass_off);
  check "an unmeasured pass is quiet" Cell.Quiet None;
  Alcotest.(check bool) "a refused row is a failure" true
    ((Reading.pass_cell (Reading.Refused "corrupt snapshot")).tone = Cell.Failure)

let test_the_peak_lag_is_the_drawn_keeper_furthest_behind () =
  let keepers =
    [ make_keeper_health ~keeper_id:"alpha"
        (make_librarian ~unread_atom_turns:5 ~unread_official_turns:3 ())
    ; make_keeper_health ~keeper_id:"beta"
        (make_librarian ~unread_atom_turns:1 ~unread_official_turns:2 ())
    ; make_keeper_health ~keeper_id:"gamma" (make_librarian ~unread_atom_turns:40 ())
    ; make_keeper_health ~keeper_id:"ghost"
        (make_librarian ~unread_atom_turns:30 ~unread_official_turns:10 ())
    ]
  in
  let index = Reading.index_of_snapshot (Some (make_snapshot keepers)) in
  let peak names =
    Reading.peak_lag (List.map (fun keeper_name -> Reading.find index ~keeper_name) names)
  in
  Alcotest.(check int) "a snapshot row the list does not draw does not set the peak" 8
    (peak [ "alpha"; "beta"; "gamma"; "delta" ]);
  Alcotest.(check int) "a drawn keeper further behind sets it" 40
    (peak [ "alpha"; "ghost" ]);
  Alcotest.(check int) "no measured lag has no peak" 0 (peak [ "gamma"; "delta" ])

let test_admission_wait_is_independent_of_a_drained_durable_pass () =
  List.iter (fun (wait, tone) ->
    let admission_wait = Masc.Keeper_librarian_pending.Admission_waiting
      {installation_id = "librarian"; request_id = "admission-original"; wait} in
    let reading = reading_of [make_keeper_health
      (make_librarian ~state:Health.Pass_drained ~admission_wait ())] "alpha" in
    check_field "durable observation stays drained"
      (Reading.Measured Health.Pass_drained) (Reading.pass_end reading);
    (match reading with
     | Reading.Row {admission_wait = Some observed; _} ->
       Alcotest.(check bool) "original admission wait survives" true (observed = admission_wait)
     | Row {admission_wait = None; _} | Unknown | No_row | Refused _ ->
       Alcotest.fail "the admission wait disappeared");
    let cell = Reading.pass_cell reading in
    Alcotest.(check bool) "execution uncertainty requests attention" true (cell.tone = tone))
    Masc.Keeper_librarian_pending.[
      Capacity, Cell.Quiet;
      Missing_after_dispatch, Cell.Attention];
  let failed = Masc.Keeper_librarian_pending.Admission_failed "pass refused" in
  let cell = Reading.pass_cell (reading_of [make_keeper_health
    (make_librarian ~state:Health.Pass_drained ~admission_wait:failed ())] "alpha") in
  Alcotest.(check bool) "a failed admission pass requests attention beside a drained pass" true
    (cell.tone = Cell.Attention)

let () =
  Alcotest.run "tui_keeper_memory_reading"
    [ ( "memory reading"
      , [ Alcotest.test_case "lag calculation rules" `Quick test_lag_rules
        ; Alcotest.test_case "row carries the servers age ladder" `Quick test_row_carries_the_servers_age_ladder
        ; Alcotest.test_case "no row vs unknown vs refused" `Quick test_no_row_vs_unknown_vs_refused
        ; Alcotest.test_case "cells formatting" `Quick test_cells_formatting
        ] )
    ; ( "view cells"
      , [ Alcotest.test_case "a reading gives its value or why it has none" `Quick
            test_a_reading_gives_its_value_or_why_it_has_none
        ; Alcotest.test_case "a reading without a row names why in every field" `Quick
            test_a_reading_without_a_row_names_why_in_every_field
        ; Alcotest.test_case "the pass cell tone follows how the pass ended" `Quick
            test_the_pass_cell_tone_follows_how_the_pass_ended
        ; Alcotest.test_case "the peak lag is the drawn keeper furthest behind" `Quick
            test_the_peak_lag_is_the_drawn_keeper_furthest_behind
        ; Alcotest.test_case "admission wait is independent of a drained durable pass" `Quick
            test_admission_wait_is_independent_of_a_drained_durable_pass
        ] )
    ]
