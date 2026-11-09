let make_librarian
    ?state
    ?unread_atom_turns
    ?unread_official_turns
    ?stalled
    ?last_success_at
    () : Masc.Tui_decode_memory_health.memory_librarian_health =
  { mlh_state = state
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
  let bins : Masc.Keeper_memory_age_bins.t =
    { under_hour = 1; under_day = 2; under_week = 3; older = 4 }
  in
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

let check_field name expected actual = Alcotest.(check bool) name true (expected = actual)

let test_a_reading_gives_its_value_or_why_it_has_none () =
  let bins : Masc.Keeper_memory_age_bins.t =
    { under_hour = 1; under_day = 2; under_week = 3; older = 4 }
  in
  let measured =
    make_keeper_health ~keeper_id:"alpha" ~updated_at:1794040000.0 ~age_bins:bins
      (make_librarian ~state:Health.Pass_pending ())
  in
  let unmeasured = make_keeper_health ~keeper_id:"beta" (make_librarian ()) in
  let refusal : Health.memory_keeper_refusal =
    { mkr_keeper_id = Some "gamma"; mkr_reason = "corrupt snapshot" }
  in
  let index =
    Reading.index_of_snapshot (Some (make_snapshot ~refusals:[ refusal ] [ measured; unmeasured ]))
  in
  let reading keeper_name = Reading.find index ~keeper_name in
  let unknown = Reading.find (Reading.index_of_snapshot None) ~keeper_name:"alpha" in
  check_field "the pass end comes from the row's librarian" (Reading.Measured Health.Pass_pending)
    (Reading.pass_end (reading "alpha"));
  check_field "the update time comes from the row" (Reading.Measured 1794040000.0)
    (Reading.updated_at (reading "alpha"));
  check_field "the age bins come from the row" (Reading.Measured bins)
    (Reading.age_bins (reading "alpha"));
  check_field "a pass the server did not measure" Reading.Unmeasured
    (Reading.pass_end (reading "beta"));
  check_field "an update the server did not stamp" Reading.Unmeasured
    (Reading.updated_at (reading "beta"));
  check_field "a ladder the server did not count" Reading.Unmeasured
    (Reading.age_bins (reading "beta"));
  check_field "a refused row" Reading.Row_refused (Reading.pass_end (reading "gamma"));
  check_field "a Keeper the snapshot has no row for" Reading.Row_absent
    (Reading.updated_at (reading "delta"));
  check_field "no snapshot" Reading.Snapshot_unknown (Reading.age_bins unknown)

let test_the_pass_cell_tone_follows_how_the_pass_ended () =
  let tone_of state =
    let keeper = make_keeper_health ~keeper_id:"alpha" (make_librarian ?state ()) in
    let index = Reading.index_of_snapshot (Some (make_snapshot [ keeper ])) in
    (Reading.pass_cell (Reading.find index ~keeper_name:"alpha")).tone
  in
  let check name expected state =
    Alcotest.(check bool) name true (expected = tone_of state)
  in
  check "a stopped pass is a failure" Masc_tui_keeper_axis_cell.Failure
    (Some (Health.Pass_stopped "lane gone"));
  check "a crashed pass is a failure" Masc_tui_keeper_axis_cell.Failure
    (Some (Health.Pass_raised "exception"));
  check "a pass that saved nothing asks for attention" Masc_tui_keeper_axis_cell.Attention
    (Some Health.Pass_not_committed);
  check "a librarian with no lane asks for attention" Masc_tui_keeper_axis_cell.Attention
    (Some Health.Pass_lane_unconfigured);
  check "a caught-up pass is quiet" Masc_tui_keeper_axis_cell.Quiet (Some Health.Pass_drained);
  check "a pending pass is quiet" Masc_tui_keeper_axis_cell.Quiet (Some Health.Pass_pending);
  check "an unmeasured pass is quiet" Masc_tui_keeper_axis_cell.Quiet None;
  let refused = Reading.Refused "corrupt snapshot" in
  Alcotest.(check bool) "a refused row is a failure" true
    ((Reading.pass_cell refused).tone = Masc_tui_keeper_axis_cell.Failure)

let test_the_peak_lag_is_the_furthest_behind_row () =
  let keeper keeper_id librarian = make_keeper_health ~keeper_id librarian in
  let index =
    Reading.index_of_snapshot
      (Some
         (make_snapshot
            [ keeper "alpha" (make_librarian ~unread_atom_turns:5 ~unread_official_turns:3 ())
            ; keeper "beta" (make_librarian ~unread_atom_turns:1 ~unread_official_turns:2 ())
            ; keeper "gamma" (make_librarian ~unread_atom_turns:40 ())
            ]))
  in
  Alcotest.(check int) "an unmeasured lag does not set the peak" 8 (Reading.peak_lag index);
  Alcotest.(check int) "no snapshot has no peak" 0
    (Reading.peak_lag (Reading.index_of_snapshot None))

let test_a_reading_without_a_row_draws_no_next_cells () =
  List.iter
    (fun (name, reading) ->
      Alcotest.(check int) (name ^ ": memory view") 0
        (List.length (Reading.lag_digest_gap_cells ~now:1794050000.0 ~peak_lag:8 reading));
      Alcotest.(check int) (name ^ ": age view") 0
        (List.length (Reading.lag_stale_facts_cells ~peak_lag:8 reading)))
    [ "unknown", Reading.Unknown; "no row", Reading.No_row; "refused", Reading.Refused "corrupt" ]

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
        ; Alcotest.test_case "the pass cell tone follows how the pass ended" `Quick
            test_the_pass_cell_tone_follows_how_the_pass_ended
        ; Alcotest.test_case "the peak lag is the furthest behind row" `Quick
            test_the_peak_lag_is_the_furthest_behind_row
        ; Alcotest.test_case "a reading without a row draws no next cells" `Quick
            test_a_reading_without_a_row_draws_no_next_cells
        ] )
    ]
