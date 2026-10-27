open Alcotest

(* A system thread belongs to the domain that started it: [Domain.self] inside
   it names that domain, and that domain's lock is the one it holds while it
   runs OCaml. *)

let with_installed_pool f =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      let pool = Domain_pool.create ~sw ~domain_count:1 (Eio.Stdenv.domain_mgr env) in
      Domain_pool_ref.set pool;
      Fun.protect ~finally:Domain_pool_ref.clear_for_tests (fun () -> f env)))
;;

let test_work_runs_on_a_pool_domain_outside_eio () =
  with_installed_pool (fun _env ->
    let caller = (Domain.self () :> int) in
    let domain, context =
      Domain_pool_ref.run_in_pool_systhread (fun () ->
        (Domain.self () :> int), Eio_guard.execution_context ())
    in
    check bool "the system thread is not the caller's domain's" true (domain <> caller);
    check bool "the work runs outside Eio" true (context = Eio_guard.Non_eio))
;;

(* Pool work that calls it again must not queue behind itself: the one worker
   of this pool is the job that is asking. *)
let test_pool_work_starts_the_thread_on_its_own_domain () =
  with_installed_pool (fun env ->
    let outcome =
      Eio.Time.with_timeout (Eio.Stdenv.clock env) 10.0 (fun () ->
        Ok
          (Domain_pool_ref.submit_cpu_or_inline (fun () ->
             let job = (Domain.self () :> int) in
             job, Domain_pool_ref.run_in_pool_systhread (fun () -> (Domain.self () :> int)))))
    in
    match outcome with
    | Error `Timeout -> fail "nested work waited for the worker that submitted it"
    | Ok (job, thread) -> check int "the thread is the job's domain's" job thread)
;;

(* Started work is not interrupted: a cancelled caller returns only after the
   work has finished, as under [Eio_unix.run_in_systhread]. *)
let test_cancelled_caller_waits_for_started_work () =
  with_installed_pool (fun env ->
    let clock = Eio.Stdenv.clock env in
    let started = Atomic.make false in
    let finished = Atomic.make false in
    Eio.Fiber.first
      (fun () ->
        Domain_pool_ref.run_in_pool_systhread (fun () ->
          Atomic.set started true;
          Unix.sleepf 0.2;
          Atomic.set finished true))
      (fun () ->
        while not (Atomic.get started) do Eio.Time.sleep clock 0.005 done);
    check bool "the work ran to its end before the caller returned" true
      (Atomic.get finished))
;;

let test_without_a_pool_the_thread_is_the_callers () =
  Eio_main.run (fun _env ->
    Domain_pool_ref.clear_for_tests ();
    let caller = (Domain.self () :> int) in
    let domain = Domain_pool_ref.run_in_pool_systhread (fun () -> (Domain.self () :> int)) in
    check int "no pool: the caller's domain starts the thread" caller domain)
;;

let () =
  run "Pool system thread"
    [ ( "placement"
      , [ test_case "work runs on a pool domain, outside Eio" `Quick
            test_work_runs_on_a_pool_domain_outside_eio
        ; test_case "pool work starts the thread on its own domain" `Quick
            test_pool_work_starts_the_thread_on_its_own_domain
        ; test_case "without a pool the thread is the caller's" `Quick
            test_without_a_pool_the_thread_is_the_callers
        ] )
    ; ( "cancellation"
      , [ test_case "a cancelled caller waits for started work" `Quick
            test_cancelled_caller_waits_for_started_work
        ] )
    ]
;;
