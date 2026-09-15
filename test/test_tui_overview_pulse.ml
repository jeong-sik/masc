(* The Overview's Pulse draws finished Keeper turns. Before any keeper-turn
   reading came back it drew eight flat bars, which read as "nothing finished". *)

let fresh () =
  Masc_tui_types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2.0 ()

let pulse state = Masc_tui_render_prim.overview_pulse_text state ~now:1000.

let test_an_unread_pulse_is_not_a_flat_line () =
  (* #36320 moved this row from the title's bracketed words to the labelled
     field's own (field_missing_reading, no brackets) because the "Pulse:"
     label in front of it already says these words are a reading's state,
     not a count -- the brackets said that a second time. This assertion
     tracked the pre-#36320 title spelling and went stale the same day. *)
  Alcotest.(check string) "unread" "not loaded" (pulse (fresh ()));
  let failed = fresh () in
  failed.Masc_tui_types.keeper_turns_error <- Some "keeper turns: HTTP 503";
  Alcotest.(check string) "failed" "load failed" (pulse failed)

let test_a_read_pulse_counts_its_windows () =
  let quiet = fresh () in
  quiet.Masc_tui_types.keeper_turns_observed_at <- Some 990.;
  Alcotest.(check string) "read, nothing finished"
    (Masc_tui_chart.sparkline [ 0; 0; 0; 0; 0; 0; 0; 0 ])
    (pulse quiet);
  let busy = fresh () in
  busy.Masc_tui_types.keeper_turns_observed_at <- Some 990.;
  busy.Masc_tui_types.keeper_turn_finishes <- [ ("alpha", 995.); ("beta", 900.) ];
  Alcotest.(check string) "the newest window on the right"
    (Masc_tui_chart.sparkline [ 0; 1; 0; 0; 0; 0; 0; 1 ])
    (pulse busy)

let () =
  Alcotest.run "tui_overview_pulse"
    [ ( "overview pulse"
      , [ Alcotest.test_case "an unread pulse is not a flat line" `Quick
            test_an_unread_pulse_is_not_a_flat_line
        ; Alcotest.test_case "a read pulse counts its windows" `Quick
            test_a_read_pulse_counts_its_windows
        ] )
    ]
