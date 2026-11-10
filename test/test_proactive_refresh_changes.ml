open Alcotest

module Refresh = Proactive_refresh

let interval_s = 10.0
let timeout_s = 2.0

let with_worker ?(warm_delay_s = 0.0) compute check_worker =
  Eio_mock.Backend.run (fun () ->
    let clock = Eio_mock.Clock.make () in
    Eio_mock.Clock.set_time clock 0.0;
    let changes = Eio.Stream.create 1 in
    let results = Eio.Stream.create 8 in
    let failures = Eio.Stream.create 8 in
    let never, _ = Eio.Promise.create () in
    Eio.Fiber.first
      (fun () ->
        Eio.Switch.run (fun sw ->
          Refresh.start_on_change ~sw
            ~clock:(clock :> float Eio.Time.clock_ty Eio.Resource.t) ~changes
            ~config:
              { (Refresh.default_config ~label:"changed-read" ~interval_s) with
                timeout_s; warm_delay_s;
                on_failure = Some (Eio.Stream.add failures) }
            ~compute
            ~on_result:(Eio.Stream.add results);
          Eio.Promise.await never))
      (fun () -> check_worker ~clock ~changes ~results ~failures))
;;

let assert_settled clock =
  Eio.Fiber.yield ();
  check bool "successful observation owns no timer" false
    (Eio_mock.Clock.try_advance clock)
;;

let test_success_has_no_periodic_scan () =
  let reads = ref 0 in
  with_worker (fun () -> incr reads; !reads)
    (fun ~clock ~changes ~results ~failures ->
      check int "initial read" 1 (Eio.Stream.take results);
      assert_settled clock;
      Eio_mock.Clock.set_time clock (interval_s *. 100.0);
      Eio.Fiber.yield ();
      check int "time alone never scans a settled source" 1 !reads;
      Eio.Stream.add changes ();
      check int "an actual input change starts a read" 2 (Eio.Stream.take results);
      assert_settled clock;
      check bool "healthy reads report no failure" true (Eio.Stream.is_empty failures))
;;

let test_change_during_read_remains_owed () =
  let release, complete = Eio.Promise.create () in
  let started, mark_started = Eio.Promise.create () in
  let reads = ref 0 and active = ref 0 and highest = ref 0 in
  with_worker
    (fun () ->
      incr reads; incr active; highest := max !highest !active;
      Fun.protect ~finally:(fun () -> decr active) (fun () ->
        if !reads = 1 then (
          Eio.Promise.resolve mark_started ();
          Eio.Promise.await release);
        !reads))
    (fun ~clock ~changes ~results ~failures:_ ->
      Eio.Promise.await started;
      for _ = 1 to 20 do
        if Eio.Stream.is_empty changes then Eio.Stream.add changes ()
      done;
      check int "the initial read is still the only active read" 1 !reads;
      Eio.Promise.resolve complete ();
      check int "the original result survives" 1 (Eio.Stream.take results);
      check int "the queued invalidation is consumed once" 2 (Eio.Stream.take results);
      check int "reads never overlap" 1 !highest;
      assert_settled clock;
      check int "the burst coalesces" 2 !reads)
;;

let test_failure_retries_then_settles () =
  let reads = ref 0 in
  with_worker
    (fun () -> incr reads; if !reads = 1 then failwith "temporary read failure"; !reads)
    (fun ~clock ~changes:_ ~results ~failures ->
      (match Eio.Stream.take failures with
       | Refresh.Raised (Failure detail) ->
           check string "the original read failure" "temporary read failure" detail
       | Refresh.Raised _ | Refresh.Timed_out _ -> fail "the original read failure was lost");
      Eio.Fiber.yield ();
      check bool "an unresolved read retains a retry timer" true
        (Eio_mock.Clock.try_advance clock);
      check int "the retry consumes the same source" 2 (Eio.Stream.take results);
      check (float 0.001) "the source retry uses its configured backoff" interval_s
        (Eio.Time.now clock);
      assert_settled clock)
;;

let test_initial_timeout_retains_retry () =
  let reads = ref 0 and retired = ref false in
  let never, _ = Eio.Promise.create () in
  with_worker
    (fun () ->
      incr reads;
      if !reads = 1 then
        Fun.protect ~finally:(fun () -> retired := true) (fun () -> Eio.Promise.await never);
      !reads)
    (fun ~clock ~changes:_ ~results ~failures ->
      Eio.Fiber.yield ();
      check bool "the initial attempt keeps its timeout" true
        (Eio_mock.Clock.try_advance clock);
      (match Eio.Stream.take failures with
       | Refresh.Timed_out { phase = Refresh.Warm_cache; _ } -> ()
       | Refresh.Timed_out { phase = Refresh.Refresh; _ } | Refresh.Raised _ ->
           fail "a cold timeout lost its typed phase");
      check bool "timed-out work retires before retry" true !retired;
      Eio.Fiber.yield ();
      check bool "timeout leaves an owed retry" true (Eio_mock.Clock.try_advance clock);
      check int "retry recovers without a new event" 2 (Eio.Stream.take results);
      assert_settled clock)
;;

let test_change_can_admit_the_initial_read () =
  with_worker ~warm_delay_s:(interval_s *. 10.0) (fun () -> ())
    (fun ~clock ~changes ~results ~failures:_ ->
      Eio.Stream.add changes ();
      Eio.Stream.take results;
      check (float 0.0) "an input need not wait for cold-start staggering" 0.0
        (Eio.Time.now clock);
      assert_settled clock)
;;

let test_cancellation_retires_work_without_publishing () =
  let started, mark_started = Eio.Promise.create () in
  let never, _ = Eio.Promise.create () in
  let retired = ref false in
  with_worker
    (fun () ->
      Fun.protect ~finally:(fun () -> retired := true) (fun () ->
        Eio.Promise.resolve mark_started ();
        Eio.Promise.await never))
    (fun ~clock:_ ~changes:_ ~results ~failures ->
      Eio.Promise.await started;
      check bool "pending work publishes no result" true (Eio.Stream.is_empty results);
      check bool "pending work invents no failure" true (Eio.Stream.is_empty failures));
  check bool "switch cancellation retires the pending read" true !retired
;;

let test_quiet_worker_allows_normal_switch_release () =
  Eio_mock.Backend.run (fun () ->
    let clock = Eio_mock.Clock.make () in
    let changes = Eio.Stream.create 1 and results = Eio.Stream.create 1 in
    let released = ref false in
    Eio.Switch.run (fun sw ->
      Eio.Switch.on_release sw (fun () -> released := true);
      Refresh.start_on_change ~sw
        ~clock:(clock :> float Eio.Time.clock_ty Eio.Resource.t) ~changes
        ~config:(Refresh.default_config ~label:"normal-scope-release" ~interval_s)
        ~compute:(fun () -> ()) ~on_result:(Eio.Stream.add results);
      Eio.Stream.take results;
      assert_settled clock);
    check bool "normal scope return retires the idle daemon before release" true !released;
    check bool "normal release leaves no worker timer" false
      (Eio_mock.Clock.try_advance clock))
;;

let test_semantic_deadline_is_consumed_once () =
  Eio_mock.Backend.run (fun () ->
    let clock = Eio_mock.Clock.make () in
    Eio_mock.Clock.set_time clock 0.0;
    let changes = Eio.Stream.create 1 and results = Eio.Stream.create 4 in
    let reads = ref 0 in
    Eio.Switch.run (fun sw ->
      Refresh.start_on_change_or_deadline ~sw
        ~clock:(clock :> float Eio.Time.clock_ty Eio.Resource.t) ~changes
        ~config:(Refresh.default_config ~label:"source-expiry" ~interval_s)
        ~compute:(fun () -> incr reads; Eio.Time.now clock)
        ~next_deadline:(fun observed -> if observed < 30.0 then Some 30.0 else None)
        ~on_result:(Eio.Stream.add results);
      check (float 0.) "initial source observation" 0.0 (Eio.Stream.take results);
      Eio.Fiber.yield ();
      check bool "the source's actual transition owns one deadline" true
        (Eio_mock.Clock.try_advance clock);
      check (float 0.) "the next read is at that transition" 30.0
        (Eio.Stream.take results);
      assert_settled clock;
      check int "an expired source does not install a new cadence" 2 !reads;
      Eio.Stream.add changes ();
      ignore (Eio.Stream.take results : float);
      assert_settled clock))
;;

let test_deadline_crossed_by_read_stays_owed () =
  Eio_mock.Backend.run (fun () ->
    let clock = Eio_mock.Clock.make () in
    Eio_mock.Clock.set_time clock 0.0;
    let changes = Eio.Stream.create 1 and results = Eio.Stream.create 4 in
    let reads = ref 0 in
    Eio.Switch.run (fun sw ->
      Refresh.start_on_change_or_deadline ~sw
        ~clock:(clock :> float Eio.Time.clock_ty Eio.Resource.t) ~changes
        ~config:{(Refresh.default_config ~label:"read-crossed-expiry" ~interval_s)
                  with timeout_s = 100.0}
        ~compute:(fun () ->
          incr reads;
          let observed = Eio.Time.now clock in
          if !reads = 1 then Eio.Time.sleep clock 40.0;
          observed)
        ~next_deadline:(fun observed -> if observed < 30.0 then Some 30.0 else None)
        ~on_result:(Eio.Stream.add results);
      check (float 0.) "the initial answer survives crossing its deadline" 0.0
        (Eio.Stream.take results);
      check (float 0.) "the elapsed transition retains its follow-up" 40.0
        (Eio.Stream.take results);
      assert_settled clock;
      check int "there is only the owed follow-up" 2 !reads))
;;

let () =
  run "change-driven refresh"
    [ "read debt",
      [ test_case "healthy idle has no periodic scan" `Quick test_success_has_no_periodic_scan
      ; test_case "changes during a read remain owed" `Quick test_change_during_read_remains_owed
      ; test_case "read failure retries then settles" `Quick test_failure_retries_then_settles
      ; test_case "initial timeout retains its retry" `Quick test_initial_timeout_retains_retry
      ; test_case "input brings initial read forward" `Quick test_change_can_admit_the_initial_read
      ; test_case "cancellation retires pending work" `Quick test_cancellation_retires_work_without_publishing
      ; test_case "quiet worker permits normal switch release" `Quick test_quiet_worker_allows_normal_switch_release
      ; test_case "semantic deadline settles after its transition" `Quick test_semantic_deadline_is_consumed_once
      ; test_case "a deadline crossed during a read stays owed" `Quick test_deadline_crossed_by_read_stays_owed
      ] ]
