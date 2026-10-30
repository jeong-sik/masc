open Alcotest

(* A system thread belongs to the domain that started it: [Domain.self] inside
   it names that domain, and that domain's lock is the one it holds while it
   runs OCaml.

   The host is process-wide and cannot be stopped, so the case without it runs
   first and the rest start it. *)

let domain () = (Domain.self () :> int)

(* A wait for the host is protected, so an Eio timeout cannot end it. A
   watchdog thread outside Eio turns a hang into a failed run instead. *)
let bounded _env seconds what f =
  let finished = Atomic.make false in
  let (_ : Thread.t) =
    Thread.create
      (fun () ->
        let rec watch left =
          if not (Atomic.get finished)
          then
            if left <= 0.
            then (
              Printf.eprintf "FAIL %s did not finish within %.0f s\n%!" what seconds;
              exit 3)
            else (
              Unix.sleepf 0.05;
              watch (left -. 0.05))
        in
        watch seconds)
      ()
  in
  Fun.protect ~finally:(fun () -> Atomic.set finished true) f
;;

let test_without_the_host_the_thread_is_the_callers () =
  Eio_main.run (fun env ->
    let caller = domain () in
    let thread = bounded env 10.0 "the call" (fun () -> Systhread_host.run domain) in
    check int "the caller's domain starts the thread" caller thread)
;;

let test_work_runs_on_the_host_outside_eio () =
  Systhread_host.start ();
  Eio_main.run (fun env ->
    let caller = domain () in
    let thread, context =
      bounded env 10.0 "the call" (fun () ->
        Systhread_host.run (fun () -> domain (), Eio_guard.execution_context ()))
    in
    check bool "the thread is not the caller's domain's" true (thread <> caller);
    check bool "the work runs outside Eio" true (context = Eio_guard.Non_eio))
;;

(* Pool work keeps its own domain: the host would serialize what pool domains
   now run in parallel. *)
let test_pool_work_keeps_its_own_domain () =
  Systhread_host.start ();
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      let pool = Domain_pool.create ~sw ~domain_count:1 (Eio.Stdenv.domain_mgr env) in
      Domain_pool_ref.set pool;
      Fun.protect ~finally:Domain_pool_ref.clear_for_tests (fun () ->
        let job, thread =
          bounded env 10.0 "the pool job" (fun () ->
            Domain_pool_ref.submit_cpu_or_inline ~name:__FUNCTION__ (fun () ->
              domain (), Systhread_host.run domain))
        in
        check int "the thread is the job's domain's" job thread)))
;;

(* A cancelled caller does not start the work; inside [Cancel.protect] it does,
   which is what a durable step run during shutdown relies on. *)
let test_a_cancelled_caller_starts_work_only_when_protected () =
  Systhread_host.start ();
  Eio_main.run (fun env ->
    let ran = Atomic.make false in
    let refused =
      Eio.Cancel.sub (fun cc ->
        Eio.Cancel.cancel cc Exit;
        match Systhread_host.run (fun () -> Atomic.set ran true) with
        | () -> false
        | exception Eio.Cancel.Cancelled _ -> true)
    in
    check bool "an unprotected cancelled call raises Cancelled" true refused;
    check bool "and its work never ran" false (Atomic.get ran);
    let value =
      bounded env 10.0 "the protected call" (fun () ->
        Eio.Cancel.sub (fun cc ->
          Eio.Cancel.cancel cc Exit;
          Eio.Cancel.protect (fun () -> Systhread_host.run (fun () -> 42))))
    in
    check int "a protected call in a cancelled context runs" 42 value)
;;

(* Once started, the work is not interrupted: the cancelled caller returns
   only after the work has finished, with its value, as under
   [Eio_unix.run_in_systhread]. *)
let test_cancelled_caller_waits_for_started_work () =
  Systhread_host.start ();
  Eio_main.run (fun env ->
    let clock = Eio.Stdenv.clock env in
    let started = Atomic.make false in
    let finished = Atomic.make false in
    let returned = ref None in
    let cancelled = ref false in
    Eio.Fiber.first
      (fun () ->
        try
          returned :=
            Some
              (Systhread_host.run (fun () ->
                 Atomic.set started true;
                 Unix.sleepf 0.5;
                 Atomic.set finished true;
                 7));
          Eio.Fiber.check ()
        with
        | Eio.Cancel.Cancelled _ as exn ->
          cancelled := true;
          raise exn)
      (fun () ->
        bounded env 10.0 "the work's start" (fun () ->
          while not (Atomic.get started) do Eio.Time.sleep clock 0.005 done));
    check bool "the caller was cancelled" true !cancelled;
    check bool "the work ran to its end before the caller returned" true (Atomic.get finished);
    check (option int) "the cancelled caller still got the work's value" (Some 7) !returned)
;;

let test_outside_eio_the_work_runs_directly () =
  Systhread_host.start ();
  let caller = Thread.id (Thread.self ()) in
  let thread = Systhread_host.run (fun () -> Thread.id (Thread.self ())) in
  check int "a non-Eio caller runs the work in its own thread" caller thread
;;

(* Each job gets its own thread on the host: a short job finishes while a
   long one is still running. *)
let test_a_long_job_does_not_delay_a_short_one () =
  Systhread_host.start ();
  Eio_main.run (fun env ->
    let release = Atomic.make false in
    let long_started = Atomic.make false in
    let short_done_while_long_ran = ref false in
    bounded env 10.0 "the two jobs" (fun () ->
      Eio.Fiber.both
        (fun () ->
          Systhread_host.run (fun () ->
            Atomic.set long_started true;
            while not (Atomic.get release) do Unix.sleepf 0.005 done))
        (fun () ->
          while not (Atomic.get long_started) do
            Eio.Time.sleep (Eio.Stdenv.clock env) 0.005
          done;
          Systhread_host.run ignore;
          short_done_while_long_ran := not (Atomic.get release);
          Atomic.set release true));
    check bool "the short job finished while the long one ran" true !short_done_while_long_ran)
;;

let test_failure_reraises_once () =
  Systhread_host.start ();
  Eio_main.run (fun env ->
    let calls = Atomic.make 0 in
    let raised =
      bounded env 10.0 "the failing call" (fun () ->
        match Systhread_host.run (fun () -> Atomic.incr calls; failwith "work failed") with
        | () -> None
        | exception Failure message -> Some message)
    in
    check (option string) "the work's exception reaches the caller" (Some "work failed") raised;
    check int "the work ran once" 1 (Atomic.get calls))
;;

let () =
  run "System thread host"
    [ ( "placement"
      , [ test_case "without the host the thread is the caller's" `Quick
            test_without_the_host_the_thread_is_the_callers
        ; test_case "work runs on the host, outside Eio" `Quick
            test_work_runs_on_the_host_outside_eio
        ; test_case "pool work keeps its own domain" `Quick test_pool_work_keeps_its_own_domain
        ] )
    ; ( "cancellation"
      , [ test_case "a cancelled caller starts work only when protected" `Quick
            test_a_cancelled_caller_starts_work_only_when_protected
        ; test_case "a cancelled caller waits for started work" `Quick
            test_cancelled_caller_waits_for_started_work
        ] )
    ; ( "failure"
      , [ test_case "an exception re-raises once" `Quick test_failure_reraises_once ] )
    ; ( "outside Eio and concurrency"
      , [ test_case "outside Eio the work runs directly" `Quick
            test_outside_eio_the_work_runs_directly
        ; test_case "a long job does not delay a short one" `Quick
            test_a_long_job_does_not_delay_a_short_one
        ] )
    ]
;;
