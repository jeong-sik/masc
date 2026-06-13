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
    let written = ref 0 in
    Console_sink.For_testing.set_writer (Some (fun _ -> incr written));
    Console_sink.For_testing.set_enqueue_active true;
    (* Fill past capacity (8192): a blocked writer must not block writers,
       only shed mirror lines. *)
    for i = 1 to 9000 do
      Console_sink.write (Printf.sprintf "line %d" i)
    done;
    check int "queue capped at capacity" 8192
      (Console_sink.For_testing.queued_count ());
    check int "overflow counted as drops" 808 (Console_sink.dropped_count ());
    let n = Console_sink.For_testing.drain_now () in
    check int "drain writes the capped batch" 8192 n)
;;

let test_writer_exception_does_not_escape () =
  with_clean_sink (fun () ->
    Console_sink.For_testing.set_writer (Some (fun _ -> failwith "fd broken"));
    Console_sink.For_testing.set_enqueue_active true;
    Console_sink.write "line a";
    Console_sink.write "line b";
    let n = Console_sink.For_testing.drain_now () in
    check int "drain survives a throwing writer" 2 n)
;;

let () =
  run "console_sink"
    [ ( "mirror_contract"
      , [ test_case "synchronous before start" `Quick test_synchronous_before_start
        ; test_case "enqueue mode defers fd write" `Quick
            test_enqueue_mode_defers_fd_write
        ; test_case "overflow drops and counts" `Quick test_overflow_drops_and_counts
        ; test_case "writer exception contained" `Quick
            test_writer_exception_does_not_escape
        ] )
    ]
;;
