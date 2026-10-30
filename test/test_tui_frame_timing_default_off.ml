(* The default-off contract of the frame-time histogram.

   test_tui_frame_timing runs with MASC_TUI_FRAME_TIMING set so its opt-in
   cases can record; this case needs the variable empty, so it is its own
   executable whose stanza sets it to the empty string. *)

module Timing = Masc_tui_frame_timing

let test_default_off_keeps_values_and_skips_names () =
  Alcotest.(check bool) "timing is off without an output path" false Timing.enabled;
  let named = ref false in
  let name _ =
    named := true;
    "unexpected"
  in
  let value = Timing.time_tagged Timing.Build ~tag:name (fun () -> 42) in
  let stage_value = Timing.time_stage_tagged ~name (fun () -> 17) in
  Alcotest.(check int) "frame value is unchanged" 42 value;
  Alcotest.(check int) "stage value is unchanged" 17 stage_value;
  Alcotest.(check bool) "name callbacks were skipped" false !named;
  Alcotest.(check bool) "no stage clock started" true
    (Option.is_none (Timing.start_stage ()))
;;

let () =
  Alcotest.run
    "tui frame timing default off"
    [ ( "default off",
        [ Alcotest.test_case "default off keeps values and skips names" `Quick
            test_default_off_keeps_values_and_skips_names
        ] )
    ]
;;
