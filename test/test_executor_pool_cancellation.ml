open Alcotest

let with_pool f =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      let pool =
        Eio.Executor_pool.create ~sw ~domain_count:1
          (Eio.Stdenv.domain_mgr env)
      in
      Executor_pool_ref.For_testing.with_pool pool (fun () -> f env sw pool)))

let test_running_job () =
  with_pool (fun env _sw _pool ->
    let started, start = Eio.Promise.create () in
    let release, release_job = Eio.Promise.create () in
    let finished, finish = Eio.Promise.create () in
    let cancelled = Atomic.make false in
    let calls = Atomic.make 0 in
    Fun.protect
      ~finally:(fun () ->
        Eio.Promise.resolve release_job ();
        Eio.Promise.await finished)
      (fun () ->
        Eio.Fiber.first
          (fun () -> Eio.Promise.await started)
          (fun () ->
            Executor_pool_ref.submit_or_inline (fun () ->
              Atomic.incr calls;
              Fun.protect ~finally:(fun () -> Eio.Promise.resolve finish ())
                (fun () ->
                  Eio.Promise.resolve start ();
                  try Eio.Promise.await release with
                  | Eio.Cancel.Cancelled _ as exn ->
                    Atomic.set cancelled true;
                    raise exn)));
        (* Bound a failing test, not the production job's deadline. Cleanup
           releases the old implementation's worker before reporting failure. *)
        let stopped =
          try
            Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 1.0
              (fun () -> Eio.Promise.await finished);
            true
          with Eio.Time.Timeout -> false
        in
        check bool "caller cancellation stops the suspended worker" true stopped;
        check bool "worker observes cancellation" true (Atomic.get cancelled);
        check int "cancelled compute is never replayed inline" 1 (Atomic.get calls)))

let test_waiting_job () =
  with_pool (fun _env sw pool ->
    let occupied, occupy = Eio.Promise.create () in
    let release, release_job = Eio.Promise.create () in
    let blocker =
      Eio.Executor_pool.submit_fork ~sw pool ~weight:1.0 (fun () ->
        Eio.Promise.resolve occupy ();
        Eio.Promise.await release)
    in
    Eio.Promise.await occupied;
    let released = ref false in
    let release_once () =
      if not !released then (
        released := true;
        Eio.Promise.resolve release_job ())
    in
    Fun.protect
      ~finally:(fun () ->
        release_once ();
        Eio.Promise.await_exn blocker)
      (fun () ->
        let submitting, submit = Eio.Promise.create () in
        let calls = Atomic.make 0 in
        Eio.Fiber.first
          (fun () -> Eio.Promise.await submitting)
          (fun () ->
            Eio.Promise.resolve submit ();
            Executor_pool_ref.submit_or_inline (fun () -> Atomic.incr calls));
        release_once ();
        Eio.Promise.await_exn blocker;
        Executor_pool_ref.submit_or_inline (fun () -> ());
        check int "cancelled waiting compute never starts" 0 (Atomic.get calls)))

let test_success_and_nested () =
  with_pool (fun _env _sw _pool ->
    let value =
      Executor_pool_ref.submit_or_inline (fun () ->
        check bool "worker context survives the cancellation boundary" true
          (Executor_pool_ref.in_worker_context ());
        Executor_pool_ref.submit_or_inline (fun () -> 42))
    in
    check int "normal and nested calls complete" 42 value;
    Executor_pool_ref.For_testing.with_pool_option None (fun () ->
      check int "no-pool fallback completes" 7
        (Executor_pool_ref.submit_or_inline (fun () -> 7))))

let () =
  run "Executor pool cancellation"
    [ "compute",
      [ test_case "running worker stops with its caller" `Quick test_running_job;
        test_case "waiting work does not run after cancellation" `Quick test_waiting_job;
        test_case "successful, nested and inline compute" `Quick test_success_and_nested ] ]
