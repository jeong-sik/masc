(** Queue ownership, backpressure and cancellation against the real Eio scheduler. *)
open Alcotest

module Q = Ide_ingest_queue

let in_eio f =
  Eio_main.run (fun env ->
    Fun.protect
      ~finally:(fun () -> Q.For_testing.reset ())
      (fun () -> Eio.Time.with_timeout_exn env#clock 5.0 f))
;;

let test_inline () =
  Q.For_testing.reset ();
  let ran = ref 0 in
  Q.submit (fun () -> incr ran);
  check int "works outside Eio" 1 !ran
;;

let test_deferred () =
  in_eio (fun () ->
    Q.For_testing.reset ();
    Q.For_testing.set_active true;
    let ran = ref 0 in
    Q.submit (fun () -> incr ran);
    check int "not run on producer" 0 !ran;
    check int "retained" 1 (Q.depth ());
    Q.drain_pending ();
    check int "drained" 1 !ran)
;;

let test_backpressure () =
  in_eio (fun () ->
    Q.For_testing.reset ~capacity_override:1 ();
    Q.For_testing.set_active true;
    let tags = ref [] in
    let job n () = tags := n :: !tags in
    Q.submit (job 1);
    Eio.Switch.run (fun sw ->
      let submitted = ref 1 in
      Eio.Fiber.fork ~sw (fun () ->
        Q.submit (job 2);
        submitted := 2;
        Q.submit (job 3);
        submitted := 3);
      Eio.Fiber.yield ();
      check int "full queue suspends producer" 1 !submitted;
      check int "bound retained" 1 (Q.depth ());
      Q.drain_pending ();
      Eio.Fiber.yield ();
      check int "one space admits one job" 2 !submitted;
      check int "still bounded" 1 (Q.depth ());
      Q.drain_pending ();
      Eio.Fiber.yield ());
    Q.drain_pending ();
    check (list int) "all accepted jobs survive FIFO" [ 1; 2; 3 ] (List.rev !tags))
;;

let cancelled_waiter ~broadcast () =
  in_eio (fun () ->
    Q.For_testing.reset ~capacity_override:1 ();
    Q.For_testing.set_active true;
    let ran = ref [] in
    Q.submit (fun () -> ran := 1 :: !ran);
    Eio.Fiber.first
      (fun () -> Q.submit (fun () -> ran := 2 :: !ran))
      (fun () ->
        (* The producer is suspended before this fiber starts. In the broadcast
           case the wake wins first, then [first] cancels it before it resumes. *)
        check int "original job remains queued" 1 (Q.depth ());
        if broadcast then Q.drain_pending ());
    Q.drain_pending ();
    check (list int) "cancelled waiter never inserts" [ 1 ] (List.rev !ran);
    check int "nothing retained" 0 (Q.depth ()))
;;

let test_concurrent_producers () =
  in_eio (fun () ->
    Q.For_testing.reset ~capacity_override:4 ();
    let producers = 12 and per_producer = 40 in
    let total = 12 * 40 in
    let tags = ref [] in
    let complete, resolve_complete = Eio.Promise.create () in
    Eio.Fiber.first
      Q.run_writer
      (fun () ->
        Eio.Switch.run (fun sw ->
          for producer = 1 to producers do
            Eio.Fiber.fork ~sw (fun () ->
              for index = 1 to per_producer do
                Q.submit (fun () ->
                  (* Re-enter the queue to prove callbacks run outside its lock. *)
                  check bool "queue bound" true (Q.depth () <= 4);
                  tags := (producer, index) :: !tags;
                  if List.length !tags = total then Eio.Promise.resolve resolve_complete ();
                  Eio.Fiber.yield ())
              done)
          done);
        Eio.Promise.await complete);
    let actual = List.rev !tags in
    check int "every job ran" total (List.length actual);
    check int "no duplicates" total (List.length (List.sort_uniq compare actual));
    for producer = 1 to producers do
      let indices = List.filter_map (fun (p, i) -> if p = producer then Some i else None) actual in
      check (list int) "each producer retains order"
        (List.init per_producer (fun i -> i + 1)) indices
    done)
;;

let test_writer_stop_releases_waiter () =
  in_eio (fun () ->
    Q.For_testing.reset ~capacity_override:1 ();
    let started, resolve_started = Eio.Promise.create () in
    let never, _resolve_never = Eio.Promise.create () in
    let done_, resolve_done = Eio.Promise.create () in
    let ran = ref [] in
    Eio.Switch.run (fun sw ->
      Eio.Fiber.first
        Q.run_writer
        (fun () ->
          Q.submit (fun () ->
            Eio.Promise.resolve resolve_started ();
            Eio.Promise.await never);
          Eio.Promise.await started;
          Q.submit (fun () -> ran := 2 :: !ran);
          Eio.Fiber.fork ~sw (fun () ->
            Q.submit (fun () -> ran := 3 :: !ran);
            Eio.Promise.resolve resolve_done ());
          Eio.Fiber.yield ();
          check int "producer waits behind retained job" 1 (Q.depth ()));
      (* Only the writer was cancelled; this producer belongs to the outer
         switch and must resume, drain the retained predecessor, then run. *)
      Eio.Promise.await done_);
    check (list int) "retained predecessor before live fallback" [ 2; 3 ] (List.rev !ran);
    check int "no orphaned jobs" 0 (Q.depth ());
    Q.submit (fun () -> ran := 4 :: !ran);
    check (list int) "writer state retired" [ 2; 3; 4 ] (List.rev !ran))
;;

let test_single_writer () =
  in_eio (fun () ->
    Q.For_testing.reset ();
    Eio.Fiber.first Q.run_writer (fun () ->
      check_raises "reject a second owner"
        (Invalid_argument "IDE ingestion writer already running") Q.run_writer);
    let ran = ref false in
    Q.submit (fun () -> ran := true);
    check bool "first owner still retires" true !ran)
;;

let test_cancelled_woken_writer_retains_job () =
  in_eio (fun () ->
    Q.For_testing.reset ();
    let ran = ref 0 in
    Eio.Fiber.first Q.run_writer (fun () -> Q.submit (fun () -> incr ran));
    check int "cancelled writer never removes pending job" 1 (Q.depth ());
    Q.drain_pending ();
    check int "retained job runs once" 1 !ran)
;;

let test_cancel_after_admission () =
  in_eio (fun () ->
    Q.For_testing.reset ();
    Q.For_testing.set_active true;
    let ran = ref 0 in
    let never, _resolve_never = Eio.Promise.create () in
    Eio.Fiber.first
      (fun () -> Q.submit (fun () -> incr ran); Eio.Promise.await never)
      (fun () -> check int "admission transferred ownership" 1 (Q.depth ()));
    Q.drain_pending ();
    check int "producer cancellation preserves accepted job once" 1 !ran)
;;

let test_failed_job () =
  in_eio (fun () ->
    Q.For_testing.reset ~capacity_override:1 ();
    let complete, resolve_complete = Eio.Promise.create () in
    Eio.Fiber.first Q.run_writer (fun () ->
      Q.submit (fun () -> raise (Failure "fixture append failure"));
      Q.submit (fun () -> Eio.Promise.resolve resolve_complete ());
      Eio.Promise.await complete))
;;

let () =
  run "IDE ingestion queue"
    [ "admission",
      [ test_case "inline without Eio" `Quick test_inline
      ; test_case "defers while active" `Quick test_deferred
      ; test_case "saturation preserves FIFO" `Quick test_backpressure
      ; test_case "cancelled full waiter" `Quick (cancelled_waiter ~broadcast:false)
      ; test_case "cancel after space broadcast" `Quick (cancelled_waiter ~broadcast:true)
      ; test_case "concurrent producers retain every job" `Quick test_concurrent_producers
      ; test_case "writer stop releases live waiter" `Quick test_writer_stop_releases_waiter
      ; test_case "single writer ownership" `Quick test_single_writer
      ; test_case "cancel woken writer before dequeue" `Quick test_cancelled_woken_writer_retains_job
      ; test_case "cancel after ownership transfer" `Quick test_cancel_after_admission
      ; test_case "failed job leaves writer usable" `Quick test_failed_job
      ] ]
