(** End-to-end round-trip test for Masc_runtime_events.

    Emits a Begin/End span via [emit_turn_start]/[emit_turn_end] into
    the current-process ring buffer and reads it back through an
    in-process cursor with [Runtime_events.Callbacks.add_user_event].

    This validates:
    - the listener is actually started by [start_listener]
    - the span-typed write carries [Begin]/[End] bounds through the
      buffer intact
    - consumers using [Runtime_events.Type.span] receive both bounds
      keyed to the same registered event handle ("masc.turn"). *)

let test_turn_span_roundtrip () =
  Masc_runtime_events.start_listener ();
  let cursor = Runtime_events.create_cursor None in
  Masc_runtime_events.emit_turn_start ();
  Masc_runtime_events.emit_turn_end ();
  let bounds_seen = ref [] in
  let span_cb _ring_idx _ts ev (bound : Runtime_events.Type.span) =
    if Runtime_events.User.name ev = "masc.turn" then bounds_seen := bound :: !bounds_seen
  in
  let callbacks =
    Runtime_events.Callbacks.create ()
    |> Runtime_events.Callbacks.add_user_event Runtime_events.Type.span span_cb
  in
  let _n = Runtime_events.read_poll cursor callbacks None in
  Runtime_events.free_cursor cursor;
  let observed = List.rev !bounds_seen in
  match observed with
  | [ Runtime_events.Type.Begin; Runtime_events.Type.End ] -> ()
  | _ -> Alcotest.failf "expected [Begin; End], got %d event(s)" (List.length observed)
;;

let () =
  Alcotest.run
    "masc_runtime_events"
    [ ( "span-roundtrip"
      , [ Alcotest.test_case
            "emit_turn_start/emit_turn_end visible to in-process cursor"
            `Quick
            test_turn_span_roundtrip
        ] )
    ]
;;
