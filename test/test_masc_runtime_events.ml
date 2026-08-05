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

(* One past the largest pid any supported platform allocates (Linux caps
   pid_max at 4194304; macOS at 99999), so no process can hold it and
   [Unix.kill] answers ESRCH.  Picking a real reaped pid would need a fork,
   which this module's own docs warn against. *)
let dead_pid () = 4194305

let with_temp_dir f =
  let dir = Filename.temp_file "masc_events_prune" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o700;
  Fun.protect
    ~finally:(fun () ->
      Array.iter (fun n -> try Sys.remove (Filename.concat dir n) with _ -> ())
        (try Sys.readdir dir with _ -> [||]);
      try Unix.rmdir dir with _ -> ())
    (fun () -> f dir)

let touch path = close_out (open_out path)

let test_prune_removes_dump_of_dead_pid () =
  with_temp_dir (fun dir ->
    let dead = Filename.concat dir (string_of_int (dead_pid ()) ^ ".events") in
    touch dead;
    Masc_runtime_events.prune_stale_dumps ~dir;
    Alcotest.(check bool) "dead pid dump removed" false (Sys.file_exists dead))

let test_prune_keeps_dump_of_live_pid () =
  with_temp_dir (fun dir ->
    let live =
      Filename.concat dir (string_of_int (Unix.getpid ()) ^ ".events")
    in
    touch live;
    Masc_runtime_events.prune_stale_dumps ~dir;
    Alcotest.(check bool) "live pid dump kept" true (Sys.file_exists live))

let test_prune_ignores_non_dump_files () =
  with_temp_dir (fun dir ->
    let keep = Filename.concat dir "notes.txt" in
    let keep_named = Filename.concat dir "olly.events" in
    touch keep;
    touch keep_named;
    Masc_runtime_events.prune_stale_dumps ~dir;
    Alcotest.(check bool) "unrelated file kept" true (Sys.file_exists keep);
    Alcotest.(check bool)
      "non-numeric .events kept" true (Sys.file_exists keep_named))

let test_prune_survives_missing_dir () =
  let dir = Filename.concat (Filename.get_temp_dir_name ()) "masc_no_such_dir" in
  (* Must log and return, not raise: pruning cannot block the listener. *)
  Masc_runtime_events.prune_stale_dumps ~dir

let () =
  Alcotest.run "masc_runtime_events"
    [ ( "span-roundtrip"
      , [ Alcotest.test_case
            "emit_turn_start/emit_turn_end visible to in-process cursor"
            `Quick test_turn_span_roundtrip
        ] )
    ; ( "prune-stale-dumps"
      , [ Alcotest.test_case "removes dump of dead pid" `Quick
            test_prune_removes_dump_of_dead_pid
        ; Alcotest.test_case "keeps dump of live pid" `Quick
            test_prune_keeps_dump_of_live_pid
        ; Alcotest.test_case "ignores non-dump files" `Quick
            test_prune_ignores_non_dump_files
        ; Alcotest.test_case "survives missing directory" `Quick
            test_prune_survives_missing_dir
        ] )
    ; ( "with_turn_span"
      , [ Alcotest.test_case "returns body result" `Quick
            test_with_turn_span_returns_body
        ; Alcotest.test_case "propagates body exception" `Quick
            test_with_turn_span_propagates_exn
        ] )
    ]
