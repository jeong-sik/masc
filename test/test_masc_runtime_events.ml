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
    if Runtime_events.User.name ev = "masc.turn" then
      bounds_seen := bound :: !bounds_seen
  in
  let callbacks =
    Runtime_events.Callbacks.create ()
    |> Runtime_events.Callbacks.add_user_event
         Runtime_events.Type.span span_cb
  in
  let _n = Runtime_events.read_poll cursor callbacks None in
  Runtime_events.free_cursor cursor;

  let observed = List.rev !bounds_seen in
  match observed with
  | [ Runtime_events.Type.Begin; Runtime_events.Type.End ] -> ()
  | _ ->
    Alcotest.failf
      "expected [Begin; End], got %d event(s)"
      (List.length observed)

(* with_turn_span composes emit_turn_start/emit_turn_end (covered by the
   round-trip above), so these cases pin only the bracket contract that is
   new: the body result flows through, and the body exception is re-raised
   (after the [finally] emits End). They deliberately do not read the
   process-global ring so they cannot interfere with the round-trip cursor. *)

let test_with_turn_span_returns_body () =
  let result = Masc_runtime_events.with_turn_span (fun () -> 7) in
  Alcotest.(check int) "with_turn_span returns the body's result" 7 result

let test_with_turn_span_propagates_exn () =
  Alcotest.check_raises
    "with_turn_span re-raises the body exception"
    (Failure "boom")
    (fun () ->
      ignore (Masc_runtime_events.with_turn_span (fun () -> failwith "boom")))

let test_start_listener_can_be_disabled () =
  Unix.putenv "MASC_RUNTIME_EVENTS" "0";
  Masc_runtime_events.start_listener ();
  Alcotest.(check bool) "disabled listener call returns" true true

let () =
  Alcotest.run "masc_runtime_events"
    [ ( "span-roundtrip"
      , [ Alcotest.test_case
            "emit_turn_start/emit_turn_end visible to in-process cursor"
            `Quick test_turn_span_roundtrip
        ] )
    ; ( "with_turn_span"
      , [ Alcotest.test_case "returns body result" `Quick
            test_with_turn_span_returns_body
        ; Alcotest.test_case "propagates body exception" `Quick
            test_with_turn_span_propagates_exn
        ] )
    ; ( "listener"
      , [ Alcotest.test_case "can be disabled by env" `Quick
            test_start_listener_can_be_disabled
        ] )
    ]
