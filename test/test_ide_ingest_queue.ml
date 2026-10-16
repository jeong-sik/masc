(** Bounded admission and ownership against the real Eio scheduler. *)
open Alcotest

module Q = Ide_ingest_queue

let check_accepted = function
  | Q.Accepted -> ()
  | Q.Capacity_refused -> fail "expected accepted ownership"
;;

let check_refused = function
  | Q.Capacity_refused -> ()
  | Q.Accepted -> fail "full queue accepted an observation"
;;

let in_eio f =
  Eio_main.run (fun env ->
    Fun.protect
      ~finally:(fun () -> Q.For_testing.reset ())
      (fun () -> Eio.Time.with_timeout_exn env#clock 5.0 f))
;;

let test_inline () =
  Q.For_testing.reset ();
  let ran = ref 0 in
  Q.submit (fun () ->
    check int "callback outside queue lock" 0 (Q.depth ());
    incr ran) |> check_accepted;
  check int "works outside Eio" 1 !ran
;;

let test_active_without_eio () =
  Q.For_testing.reset ~capacity_override:1 ();
  Q.For_testing.set_active true;
  let ran = ref 0 in
  Q.submit (fun () -> incr ran) |> check_accepted;
  Q.submit (fun () -> ran := 100) |> check_refused;
  check int "producer runs no callback" 0 !ran;
  check int "accepted job retained" 1 (Q.depth ());
  Q.drain_pending ();
  check int "refused callback was not retained" 1 !ran;
  Q.For_testing.reset ()
;;

let test_saturation_preserves_accepted_fifo () =
  in_eio (fun () ->
    Q.For_testing.reset ~capacity_override:2 ();
    Q.For_testing.set_active true;
    let ran = ref [] in
    let job n () = ran := n :: !ran in
    Q.submit (job 1) |> check_accepted;
    Q.submit (job 2) |> check_accepted;
    Q.submit (job 90) |> check_refused;
    Q.submit (job 91) |> check_refused;
    check int "bounded accepted buffer" 2 (Q.depth ());
    Q.drain_pending ();
    Q.submit (job 3) |> check_accepted;
    Q.drain_pending ();
    check (list int) "accepted FIFO intact, refused callbacks never run"
      [1; 2; 3] (List.rev !ran))
;;

let test_stalled_writer_does_not_park_producers () =
  in_eio (fun () ->
    Q.For_testing.reset ~capacity_override:2 ();
    let started, start = Eio.Promise.create () in
    let release, release_writer = Eio.Promise.create () in
    let complete, done_ = Eio.Promise.create () in
    let ran = ref [] and producers_returned = ref 0 in
    Eio.Fiber.first Q.run_writer (fun () ->
      Q.submit (fun () ->
        Eio.Promise.resolve start ();
        Eio.Promise.await release;
        ran := 1 :: !ran) |> check_accepted;
      Eio.Promise.await started;
      Q.submit (fun () -> ran := 2 :: !ran) |> check_accepted;
      Q.submit (fun () -> ran := 3 :: !ran; Eio.Promise.resolve done_ ()) |> check_accepted;
      let producer () =
        Q.submit (fun () -> ran := 99 :: !ran) |> check_refused;
        incr producers_returned
      in
      Eio.Fiber.both producer producer;
      check int "both unrelated producers return while writer is stalled" 2 !producers_returned;
      check int "writer still suspended" 0 (List.length !ran);
      check int "accepted queue intact" 2 (Q.depth ());
      Eio.Promise.resolve release_writer ();
      Eio.Promise.await complete);
    check (list int) "accepted jobs run once in FIFO order" [1; 2; 3] (List.rev !ran))
;;

let test_writer_reentry_at_capacity () =
  in_eio (fun () ->
    Q.For_testing.reset ~capacity_override:1 ();
    let started, start = Eio.Promise.create () in
    let release, release_writer = Eio.Promise.create () in
    let complete, done_ = Eio.Promise.create () in
    let ran = ref [] in
    Eio.Fiber.first Q.run_writer (fun () ->
      Q.submit (fun () ->
        Eio.Promise.resolve start ();
        Eio.Promise.await release;
        Q.submit (fun () -> ran := 99 :: !ran) |> check_refused;
        ran := 1 :: !ran) |> check_accepted;
      Eio.Promise.await started;
      Q.submit (fun () -> ran := 2 :: !ran; Eio.Promise.resolve done_ ()) |> check_accepted;
      Eio.Promise.resolve release_writer ();
      Eio.Promise.await complete);
    check (list int) "writer reentry cannot wait for itself" [1; 2] (List.rev !ran))
;;

let test_concurrent_producers () =
  in_eio (fun () ->
    Q.For_testing.reset ~capacity_override:4 ();
    let accepted = ref [] and refused = ref 0 and ran = ref [] in
    Eio.Fiber.first Q.run_writer (fun () ->
      Eio.Switch.run (fun sw ->
        for producer = 1 to 12 do
          Eio.Fiber.fork ~sw (fun () ->
            for index = 1 to 40 do
              (match Q.submit (fun () ->
                check bool "callback can inspect queue" true (Q.depth () <= 4);
                ran := (producer, index) :: !ran;
                Eio.Fiber.yield ()) with
               | Q.Accepted -> accepted := (producer, index) :: !accepted
               | Q.Capacity_refused -> incr refused);
              Eio.Fiber.yield ()
            done)
        done);
      while List.length !ran < List.length !accepted do Eio.Fiber.yield () done);
    check int "each offer has one typed decision" 480 (List.length !accepted + !refused);
    check bool "saturation exercised" true (!refused > 0);
    check (list (pair int int)) "exact accepted FIFO, no duplicate or refused effects"
      (List.rev !accepted) (List.rev !ran))
;;

let test_writer_stop_retains_pending () =
  in_eio (fun () ->
    Q.For_testing.reset ~capacity_override:1 ();
    let started, start = Eio.Promise.create () in
    let never, _ = Eio.Promise.create () in
    let ran = ref [] in
    Eio.Fiber.first Q.run_writer (fun () ->
      Q.submit (fun () -> Eio.Promise.resolve start (); Eio.Promise.await never) |> check_accepted;
      Eio.Promise.await started;
      Q.submit (fun () -> ran := 2 :: !ran) |> check_accepted;
      Q.submit (fun () -> ran := 99 :: !ran) |> check_refused);
    Q.submit (fun () -> ran := 3 :: !ran) |> check_accepted;
    check (list int) "inactive fallback drains accepted predecessor" [2; 3] (List.rev !ran);
    check int "no orphaned jobs" 0 (Q.depth ()))
;;

let test_single_writer () =
  in_eio (fun () ->
    Q.For_testing.reset ();
    Eio.Fiber.first Q.run_writer (fun () ->
      check_raises "reject a second owner"
        (Invalid_argument "IDE ingestion writer already running") Q.run_writer);
    let ran = ref false in
    Q.submit (fun () -> ran := true) |> check_accepted;
    check bool "first owner still retires" true !ran)
;;

let test_cancelled_woken_writer_retains_job () =
  in_eio (fun () ->
    Q.For_testing.reset ();
    let ran = ref 0 in
    Eio.Fiber.first Q.run_writer (fun () -> Q.submit (fun () -> incr ran) |> check_accepted);
    check int "cancelled writer never removes pending job" 1 (Q.depth ());
    Q.drain_pending ();
    check int "retained job runs once" 1 !ran)
;;

let test_cancel_after_admission () =
  in_eio (fun () ->
    Q.For_testing.reset ();
    Q.For_testing.set_active true;
    let ran = ref 0 in
    let never, _ = Eio.Promise.create () in
    Eio.Fiber.first
      (fun () -> Q.submit (fun () -> incr ran) |> check_accepted; Eio.Promise.await never)
      (fun () -> check int "admission transferred ownership" 1 (Q.depth ()));
    Q.drain_pending ();
    check int "producer cancellation preserves accepted job once" 1 !ran)
;;

let test_failed_job () =
  in_eio (fun () ->
    Q.For_testing.reset ~capacity_override:2 ();
    let complete, done_ = Eio.Promise.create () in
    Eio.Fiber.first Q.run_writer (fun () ->
      Q.submit (fun () -> raise (Failure "fixture append failure")) |> check_accepted;
      Q.submit (fun () -> Eio.Promise.resolve done_ ()) |> check_accepted;
      Eio.Promise.await complete))
;;

let () =
  run "IDE ingestion queue"
    [ "admission",
      [ test_case "inline without Eio" `Quick test_inline
      ; test_case "active and full without Eio" `Quick test_active_without_eio
      ; test_case "saturation preserves accepted FIFO" `Quick test_saturation_preserves_accepted_fifo
      ; test_case "stalled writer leaves producers running" `Quick test_stalled_writer_does_not_park_producers
      ; test_case "writer callback reentry at capacity" `Quick test_writer_reentry_at_capacity
      ; test_case "concurrent offers have exact accepted ownership" `Quick test_concurrent_producers
      ; test_case "writer stop retains accepted pending jobs" `Quick test_writer_stop_retains_pending
      ; test_case "single writer ownership" `Quick test_single_writer
      ; test_case "cancel woken writer before dequeue" `Quick test_cancelled_woken_writer_retains_job
      ; test_case "cancel after ownership transfer" `Quick test_cancel_after_admission
      ; test_case "failed job leaves writer usable" `Quick test_failed_job
      ] ]
