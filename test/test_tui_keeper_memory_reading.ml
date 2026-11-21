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

module Reading = Masc_tui_keeper_memory_reading
module Health = Masc.Tui_decode_memory_health

let field_label = function
  | Reading.Measured _ -> "measured"
  | Reading.Unmeasured -> "unmeasured"
  | Reading.No_snapshot -> "no snapshot"
  | Reading.Snapshot_unknown -> "snapshot unknown"
  | Reading.Row_absent -> "row absent"
  | Reading.Row_refused -> "row refused"

let reading_of keepers ?(refusals = []) keeper_name =
  Reading.find
    (Reading.index_of_snapshot (Some (make_snapshot ~refusals keepers)))
    ~keeper_name

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

let () =
  Alcotest.run "tui_keeper_memory_reading"
    [ ( "view cells"
      , [ Alcotest.test_case "a reading without a row names why in every field" `Quick
            test_a_reading_without_a_row_names_why_in_every_field
        ] )
    ]
