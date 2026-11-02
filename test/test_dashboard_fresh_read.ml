open Alcotest

let with_pool ~domain_count f =
  Eio_main.run (fun env ->
    Eio_guard.enable ();
    Eio.Switch.run (fun sw ->
      let clock = Eio.Stdenv.clock env in
      let pool = Domain_pool.create ~sw ~domain_count (Eio.Stdenv.domain_mgr env) in
      Eio_context.set_switch sw;
      Fun.protect ~finally:Eio_context.For_testing.clear_root_switch (fun () ->
        Executor_pool_ref.For_testing.with_pool (Domain_pool.executor_pool pool) (fun () ->
          Eio.Time.with_timeout_exn clock 5. (fun () -> f ~sw ~clock)))))

let read gate ~key body =
  Dashboard_fresh_read.run gate ~key (Pool_work.cpu ~name:__FUNCTION__ body)

let test_only_callers_admitted_before_worker_start_share () =
  with_pool ~domain_count:1 (fun ~sw ~clock:_ ->
    let held, hold = Eio.Promise.create () in
    let release, release_held = Eio.Promise.create () in
    let blocker = Eio.Fiber.fork_promise ~sw (fun () ->
      Executor_pool_ref.submit_or_inline ~name:__FUNCTION__ (fun () ->
        Eio.Promise.resolve hold (); Eio.Promise.await release)) in
    Eio.Promise.await held;
    let gate = Dashboard_fresh_read.create () in
    let runs = Atomic.make 0 in
    let work () = Atomic.incr runs; "fresh" in
    let a = Eio.Fiber.fork_promise ~sw (fun () -> read gate ~key:"scope" work) in
    let b = Eio.Fiber.fork_promise ~sw (fun () -> read gate ~key:"scope" work) in
    Eio.Promise.resolve release_held ();
    Eio.Promise.await_exn blocker;
    check string "first reader" "fresh" (Eio.Promise.await_exn a);
    check string "reader admitted before work started" "fresh" (Eio.Promise.await_exn b);
    check int "one calculation" 1 (Atomic.get runs);
    check string "a later caller starts a new read" "fresh" (read gate ~key:"scope" work);
    check int "no completed result retained" 2 (Atomic.get runs))

let test_reader_after_write_gets_a_later_calculation () =
  with_pool ~domain_count:1 (fun ~sw ~clock:_ ->
    let gate = Dashboard_fresh_read.create () in
    let value = Atomic.make "before" in
    let started, mark_started = Eio.Promise.create () in
    let finish, release = Eio.Promise.create () in
    let a = Eio.Fiber.fork_promise ~sw (fun () -> read gate ~key:"scope" (fun () ->
      let snapshot = Atomic.get value in
      Eio.Promise.resolve mark_started ();
      Eio.Promise.await finish;
      snapshot)) in
    Eio.Promise.await started;
    Atomic.set value "after";
    let b = Eio.Fiber.fork_promise ~sw (fun () -> read gate ~key:"scope" (fun () -> Atomic.get value)) in
    Eio.Promise.resolve release ();
    check string "earlier read" "before" (Eio.Promise.await_exn a);
    check string "later reader sees the write" "after" (Eio.Promise.await_exn b))

let test_cancelled_leader_does_not_cancel_joined_reader () =
  with_pool ~domain_count:1 (fun ~sw ~clock ->
    let gate = Dashboard_fresh_read.create () in
    let held, mark_held = Eio.Promise.create () in
    let unhold, release_held = Eio.Promise.create () in
    let blocker = Eio.Fiber.fork_promise ~sw (fun () ->
      Executor_pool_ref.submit_or_inline ~name:__FUNCTION__ (fun () ->
        Eio.Promise.resolve mark_held (); Eio.Promise.await unhold)) in
    Eio.Promise.await held;
    let started, mark_started = Eio.Promise.create () in
    let finish, release = Eio.Promise.create () in
    let runs = Atomic.make 0 in
    let work () =
      Atomic.incr runs;
      Eio.Promise.resolve mark_started ();
      Eio.Promise.await finish;
      "shared" in
    let a = Eio.Fiber.fork_promise ~sw (fun () ->
      Eio.Time.with_timeout clock 0.05 (fun () -> read gate ~key:"scope" work)) in
    let b = Eio.Fiber.fork_promise ~sw (fun () -> read gate ~key:"scope" work) in
    Eio.Promise.resolve release_held ();
    Eio.Promise.await_exn blocker;
    Eio.Promise.await started;
    (match Eio.Promise.await_exn a with Error `Timeout -> () | Ok _ -> fail "leader did not time out");
    Eio.Promise.resolve release ();
    check string "joined reader gets the original result" "shared" (Eio.Promise.await_exn b);
    check int "the shared worker was not restarted" 1 (Atomic.get runs))

let test_later_reader_runs_while_first_read_is_open () =
  with_pool ~domain_count:2 (fun ~sw ~clock:_ ->
    let gate = Dashboard_fresh_read.create () in
    let value = Atomic.make "before" in
    let started, mark_started = Eio.Promise.create () in
    let finish, release = Eio.Promise.create () in
    let a = Eio.Fiber.fork_promise ~sw (fun () -> read gate ~key:"scope" (fun () ->
      let snapshot = Atomic.get value in
      Eio.Promise.resolve mark_started ();
      Eio.Promise.await finish;
      snapshot)) in
    Eio.Promise.await started;
    Atomic.set value "after";
    check string "later reader need not wait for the earlier worker" "after"
      (read gate ~key:"scope" (fun () -> Atomic.get value));
    Eio.Promise.resolve release ();
    check string "earlier read keeps its snapshot" "before" (Eio.Promise.await_exn a))

let test_last_waiter_cancels_producer_and_future_reads_work () =
  with_pool ~domain_count:1 (fun ~sw ~clock ->
    let gate = Dashboard_fresh_read.create () in
    let started, mark_started = Eio.Promise.create () in
    let settled, mark_settled = Eio.Promise.create () in
    let a = Eio.Fiber.fork_promise ~sw (fun () ->
      Eio.Time.with_timeout clock 0.05 (fun () -> read gate ~key:"scope" (fun () ->
        Fun.protect ~finally:(fun () -> Eio.Promise.resolve mark_settled ()) (fun () ->
          Eio.Promise.resolve mark_started (); Eio.Fiber.await_cancel ())))) in
    Eio.Promise.await started;
    (match Eio.Promise.await_exn a with Error `Timeout -> () | Ok _ -> fail "reader did not time out");
    Eio.Promise.await settled;
    check string "future reader still works" "new" (read gate ~key:"scope" (fun () -> "new")))

let test_distinct_scopes_do_not_share () =
  with_pool ~domain_count:2 (fun ~sw ~clock:_ ->
    let gate = Dashboard_fresh_read.create () in
    let started, mark_started = Eio.Promise.create () in
    let finish, release = Eio.Promise.create () in
    let a = Eio.Fiber.fork_promise ~sw (fun () -> read gate ~key:"scope-a" (fun () ->
      Eio.Promise.resolve mark_started (); Eio.Promise.await finish; "a")) in
    Eio.Promise.await started;
    check string "other scope reads independently" "b" (read gate ~key:"scope-b" (fun () -> "b"));
    Eio.Promise.resolve release ();
    check string "first scope completes" "a" (Eio.Promise.await_exn a))

let () = run "fresh dashboard reads" ["batch", [
  test_case "queued readers share only before work starts" `Quick test_only_callers_admitted_before_worker_start_share;
  test_case "a later reader sees an intervening write" `Quick test_reader_after_write_gets_a_later_calculation;
  test_case "leader cancellation preserves joined readers" `Quick test_cancelled_leader_does_not_cancel_joined_reader;
  test_case "later read can run beside an earlier read" `Quick test_later_reader_runs_while_first_read_is_open;
  test_case "last waiter cancels and releases producer" `Quick test_last_waiter_cancels_producer_and_future_reads_work;
  test_case "workspace scopes remain separate" `Quick test_distinct_scopes_do_not_share;
]]
