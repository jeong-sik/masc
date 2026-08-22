(** Console_sink — the console mirror must never block log producers.

    Contract under test (issue #20684):
    - synchronous before enqueue mode (historical behavior)
    - enqueue mode: write returns without touching the fd writer
    - bounded queue: overflow drops incoming mirror lines and counts them
    - drain writes queued lines in order and reports drops once *)

open Alcotest

let with_clean_sink f =
  Console_sink.For_testing.reset ();
  Fun.protect ~finally:Console_sink.For_testing.reset f
;;

let test_synchronous_before_start () =
  with_clean_sink (fun () ->
    let written = ref [] in
    Console_sink.For_testing.set_writer (Some (fun l -> written := l :: !written));
    Console_sink.write "direct line";
    check (list string) "written immediately, nothing queued" [ "direct line" ]
      !written;
    check int "queue untouched" 0 (Console_sink.For_testing.queued_count ()))
;;

let test_after_write_observer_lifecycle () =
  with_clean_sink (fun () ->
    let events = ref [] in
    Console_sink.For_testing.set_writer
      (Some (fun line -> events := ("write:" ^ line) :: !events));
    Console_sink.set_after_write_observer
      (Some (fun () -> events := "observer" :: !events));
    Console_sink.write "first";
    check (list string) "observer runs after the writer attempt"
      [ "write:first"; "observer" ]
      (List.rev !events);
    Console_sink.set_after_write_observer None;
    Console_sink.write "second";
    check (list string) "clearing removes the observer"
      [ "write:first"; "observer"; "write:second" ]
      (List.rev !events);
    let observed_after_reset = ref 0 in
    Console_sink.set_after_write_observer
      (Some (fun () -> incr observed_after_reset));
    Console_sink.For_testing.reset ();
    Console_sink.For_testing.set_writer (Some (fun _ -> ()));
    Console_sink.write "after reset";
    check int "test reset removes the observer" 0 !observed_after_reset)
;;

let test_enqueue_mode_defers_fd_write () =
  with_clean_sink (fun () ->
    let written = ref [] in
    Console_sink.For_testing.set_writer (Some (fun l -> written := l :: !written));
    Console_sink.For_testing.set_enqueue_active true;
    Console_sink.write "queued line";
    check (list string) "fd writer not called by producer" [] !written;
    check int "line queued" 1 (Console_sink.For_testing.queued_count ());
    let n = Console_sink.For_testing.drain_now () in
    check int "drain wrote the line" 1 n;
    check (list string) "drained to writer" [ "queued line" ] !written)
;;

let test_overflow_drops_and_counts () =
  with_clean_sink (fun () ->
    let written = ref [] in
    let observed = ref 0 in
    Console_sink.For_testing.set_writer
      (Some (fun line -> written := line :: !written));
    Console_sink.set_after_write_observer (Some (fun () -> incr observed));
    Console_sink.For_testing.set_enqueue_active true;
    (* Fill past capacity (8192): a blocked writer must not block writers,
       only shed mirror lines. *)
    for i = 1 to 9000 do
      Console_sink.write (Printf.sprintf "line %d" i)
    done;
    check int "queue capped at capacity" 8192
      (Console_sink.For_testing.queued_count ());
    check int "overflow counted as drops" 808 (Console_sink.dropped_count ());
    let (n, last_reported_drops) =
      Console_sink.For_testing.drain_now_since 0
    in
    check int "drain writes the capped batch" 8192 n;
    check int "drop report advances to the observed total" 808
      last_reported_drops;
    check int "queued lines plus one drop marker reach the writer" 8193
      (List.length !written);
    check int "drop marker invokes the observer" 8193 !observed;
    check string "drop marker reports the exact delta"
      "[console-sink] dropped 808 console line(s) while the console writer was blocked (file sink unaffected)"
      (List.hd !written);
    let (_n, last_reported_drops) =
      Console_sink.For_testing.drain_now_since last_reported_drops
    in
    check int "the same drop total is reported only once" 8193
      (List.length !written);
    check int "an omitted duplicate marker cannot notify" 8193 !observed;
    check int "reported total stays stable" 808 last_reported_drops)
;;

let test_writer_and_observer_exception_contract () =
  with_clean_sink (fun () ->
    let observed = ref 0 in
    Console_sink.set_after_write_observer (Some (fun () -> incr observed));
    Console_sink.For_testing.set_writer (Some (fun _ -> failwith "fd broken"));
    Console_sink.For_testing.set_enqueue_active true;
    Console_sink.write "line a";
    Console_sink.write "line b";
    let n = Console_sink.For_testing.drain_now () in
    check int "drain survives a throwing writer" 2 n;
    check int "every attempted queued write notifies healthy observers" 2
      !observed;
    Console_sink.For_testing.set_enqueue_active false;
    let synchronous_observed = ref 0 in
    Console_sink.set_after_write_observer
      (Some (fun () -> incr synchronous_observed));
    check_raises "synchronous writer exception remains visible"
      (Failure "fd broken")
      (fun () -> Console_sink.write "line c");
    check int "failed synchronous attempt still notifies" 1
      !synchronous_observed;
    Console_sink.For_testing.set_writer (Some (fun _ -> ()));
    Console_sink.set_after_write_observer
      (Some (fun () -> failwith "observer broken"));
    Console_sink.write "line d")
;;

let () =
  run "console_sink"
    [ ( "mirror_contract"
      , [ test_case "synchronous before start" `Quick test_synchronous_before_start
        ; test_case "after-write observer lifecycle" `Quick
            test_after_write_observer_lifecycle
        ; test_case "enqueue mode defers fd write" `Quick
            test_enqueue_mode_defers_fd_write
        ; test_case "overflow drops and counts" `Quick test_overflow_drops_and_counts
        ; test_case "writer and observer exception contract" `Quick
            test_writer_and_observer_exception_contract
        ] )
    ]
;;
