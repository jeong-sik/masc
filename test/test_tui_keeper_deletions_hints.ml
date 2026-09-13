(* The Keeper deletion overlay's key row names the keys that act on what it
   shows. It named [j/k] and [t] on a failed read too, where neither does
   anything. *)

let fresh () =
  Masc_tui_types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2.0 ()

let record ~can_retry : Masc_tui_keeper_control.deletion_row =
  let receipt : Masc.Keeper_configuration_removal.receipt =
    { operation_id = Masc.Keeper_shutdown_types.Operation_id.generate ()
    ; keeper_name = "alpha"
    ; actor = "tester"
    ; source_sha256 = ""
    ; source_path = ""
    ; requested_at = ""
    ; updated_at = ""
    ; state = Masc.Keeper_configuration_removal.Cleanup_required "disk"
    ; last_error = None
    }
  in
  { operation = Masc_tui_keeper_control.Configuration_removal receipt
  ; completed = false
  ; can_retry
  }

let with_records records =
  let state = fresh () in
  state.Masc_tui_types.keeper_deletions <-
    Some (Ok { Masc_tui_keeper_control.operations = records; errors = [] });
  state

let has key row =
  String.split_on_char ' ' row
  |> List.exists (String.starts_with ~prefix:(key ^ ":"))

let hints state = Masc_tui_render_prim.keeper_deletions_hints state ~scrollable:false

let test_a_failed_read_offers_reload_and_close () =
  let state = fresh () in
  state.Masc_tui_types.keeper_deletions <- Some (Error "HTTP 503");
  Alcotest.(check string) "only what acts on a failed read" "r:조회  Esc:닫기"
    (hints state)

let test_one_record_does_not_offer_stepping () =
  Alcotest.(check bool) "no j/k with one record" false
    (has "j/k" (hints (with_records [ record ~can_retry:false ])))

let test_retry_follows_the_selected_record () =
  let state = with_records [ record ~can_retry:false; record ~can_retry:true ] in
  Alcotest.(check bool) "j/k with two records" true (has "j/k" (hints state));
  Alcotest.(check bool) "no t on a record that cannot retry" false (has "t" (hints state));
  state.Masc_tui_types.keeper_deletions_cursor <- 1;
  Alcotest.(check bool) "t on the record that can" true (has "t" (hints state))

let test_the_record_scroll_needs_a_long_record () =
  let state = with_records [ record ~can_retry:false ] in
  Alcotest.(check bool) "no record scroll when it fits" false
    (has "J/K/PgUp/PgDn" (Masc_tui_render_prim.keeper_deletions_hints state ~scrollable:false));
  Alcotest.(check bool) "record scroll when it does not" true
    (has "J/K/PgUp/PgDn" (Masc_tui_render_prim.keeper_deletions_hints state ~scrollable:true))

let () =
  Alcotest.run "tui_keeper_deletions_hints"
    [ ( "keeper deletions hints"
      , [ Alcotest.test_case "a failed read offers reload and close" `Quick
            test_a_failed_read_offers_reload_and_close
        ; Alcotest.test_case "one record does not offer stepping" `Quick
            test_one_record_does_not_offer_stepping
        ; Alcotest.test_case "retry follows the selected record" `Quick
            test_retry_follows_the_selected_record
        ; Alcotest.test_case "the record scroll needs a long record" `Quick
            test_the_record_scroll_needs_a_long_record
        ] )
    ]
