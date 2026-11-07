let make_librarian
    ?unread_atom_turns
    ?unread_official_turns
    ?stalled
    ?last_success_at
    () : Masc.Tui_decode_memory_health.memory_librarian_health =
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
    ?(keeper_id = "alpha")
    ?(added = 1)
    ?(removed = 0)
    ?(source_invalidations = 0)
    ?updated_at
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
  Alcotest.(check bool) "third cell contains clock +47m +1 -0" true
    (String.starts_with ~prefix:"+47m +1 -0" (List.nth cells 2).text);
  Alcotest.(check string) "fourth cell is stale ×2" "stale ×2" (List.nth cells 3).text
;;

let () =
  Alcotest.run "tui_keeper_memory_reading"
    [ ( "memory reading"
      , [ Alcotest.test_case "lag calculation rules" `Quick test_lag_rules
        ; Alcotest.test_case "no row vs unknown vs refused" `Quick test_no_row_vs_unknown_vs_refused
        ; Alcotest.test_case "cells formatting" `Quick test_cells_formatting
        ] )
    ]
