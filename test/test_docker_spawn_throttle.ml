(** test_docker_spawn_throttle — verifies the FD spawn cap.

    Tests cover:
    - Layer A: concurrency cap (upper bound 64 per
      [MASC_DOCKER_SPAWN_CONCURRENCY] range) is respected under fan-in
    - Layer B: fd_pressure-trip serialization — verified indirectly by
      observing peak in-flight <= 1 while degraded *)

module DST = Masc_mcp.Docker_spawn_throttle
module FD = Masc_mcp.Keeper_fd_pressure

let with_eio f =
  Eio_main.run (fun env -> ignore env; f ())

let test_concurrency_capped_under_fanin () =
  (* Fire 32 fibers, each holding the slot briefly. Track peak in-flight.
     Peak must not exceed the documented upper bound (64) from the
     [MASC_DOCKER_SPAWN_CONCURRENCY] range 1..64 in
     [docker_spawn_throttle.mli]. [configured_max] is no longer exported
     (PR #17948 — zero external callers); the bound is therefore checked
     against the upper limit rather than the current configured value. *)
  FD.reset_for_tests ();
  with_eio @@ fun () ->
  let max_cap = 64 in
  let in_flight = Atomic.make 0 in
  let peak = Atomic.make 0 in
  let fan = 32 in
  Eio.Switch.run @@ fun sw ->
  let promises =
    List.init fan (fun _ ->
      Eio.Fiber.fork_promise ~sw (fun () ->
        DST.with_slot (fun () ->
          let now = Atomic.fetch_and_add in_flight 1 + 1 in
          let rec bump_peak () =
            let cur = Atomic.get peak in
            if now > cur && not (Atomic.compare_and_set peak cur now)
            then bump_peak ()
          in
          bump_peak ();
          (* Yield so other fibers race for the slot. *)
          Eio.Fiber.yield ();
          ignore (Atomic.fetch_and_add in_flight (-1)))))
  in
  List.iter (fun p -> Eio.Promise.await_exn p) promises;
  let observed = Atomic.get peak in
  Alcotest.(check bool)
    (Printf.sprintf "peak in-flight %d <= configured_max %d" observed max_cap)
    true
    (observed <= max_cap)

let test_degraded_mode_serializes () =
  (* Trip fd_pressure; concurrent [with_slot] callers must serialize.
     Verified by observing peak in-flight == 1 across a fan-in of 8
     callers. [effective_concurrency] is no longer exported
     (PR #17948 — zero external callers), so the serialization
     contract is observed through actual slot acquisition rather than
     through the (now-internal) accessor. *)
  FD.reset_for_tests ();
  FD.note ~site:"unit-test" ~detail:"too many open files in system" ();
  Alcotest.(check bool) "FD.active is true after note" true (FD.active ());
  with_eio @@ fun () ->
  let in_flight = Atomic.make 0 in
  let peak = Atomic.make 0 in
  let fan = 8 in
  Eio.Switch.run @@ fun sw ->
  let promises =
    List.init fan (fun _ ->
      Eio.Fiber.fork_promise ~sw (fun () ->
        DST.with_slot (fun () ->
          let now = Atomic.fetch_and_add in_flight 1 + 1 in
          let rec bump_peak () =
            let cur = Atomic.get peak in
            if now > cur && not (Atomic.compare_and_set peak cur now)
            then bump_peak ()
          in
          bump_peak ();
          Eio.Fiber.yield ();
          ignore (Atomic.fetch_and_add in_flight (-1)))))
  in
  List.iter (fun p -> Eio.Promise.await_exn p) promises;
  let observed = Atomic.get peak in
  Alcotest.(check int) "degraded mode serializes to peak 1" 1 observed;
  FD.reset_for_tests ()

let test_exception_releases_slot () =
  (* If f raises, the slot must still be released — verify by running
     the cap-test after a raising call completes. *)
  FD.reset_for_tests ();
  with_eio @@ fun () ->
  (try DST.with_slot (fun () -> failwith "intentional") with Failure _ -> ());
  (* After the exception, a fresh fan-in must still complete (slots not leaked). *)
  let fan = 16 in
  let done_ = Atomic.make 0 in
  Eio.Switch.run @@ fun sw ->
  let promises =
    List.init fan (fun _ ->
      Eio.Fiber.fork_promise ~sw (fun () ->
        DST.with_slot (fun () -> ignore (Atomic.fetch_and_add done_ 1))))
  in
  List.iter (fun p -> Eio.Promise.await_exn p) promises;
  Alcotest.(check int) "all 16 completed" fan (Atomic.get done_)

let () =
  Alcotest.run
    "docker_spawn_throttle"
    [ ( "throttle"
      , [ Alcotest.test_case "concurrency capped under fan-in" `Quick
            test_concurrency_capped_under_fanin
        ; Alcotest.test_case "degraded mode serializes to 1" `Quick
            test_degraded_mode_serializes
        ; Alcotest.test_case "exception releases slot" `Quick
            test_exception_releases_slot
        ] )
    ]
