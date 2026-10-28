(* Where [Keeper_tool_call_index] runs its file and SQLite work. A system
   thread shares its domain's runtime lock, so work in a system thread of the
   main domain holds the lock the main scheduler needs. With a pool installed
   the work runs on a pool domain; without one, and from a pool job, it stays
   where the caller is. *)

module Index = Keeper_tool_call_index.For_testing

let domain_id () = (Domain.self () :> int)

let with_pool env f =
  let previous = Domain_pool_ref.get () in
  Fun.protect
    ~finally:(fun () ->
      match previous with
      | None -> Domain_pool_ref.clear_for_tests ()
      | Some pool -> Domain_pool_ref.set pool)
    (fun () ->
      Eio.Switch.run (fun sw ->
        Domain_pool_ref.set
          (Domain_pool.create ~sw ~domain_count:1 (Eio.Stdenv.domain_mgr env));
        f ()))

let without_pool f =
  let previous = Domain_pool_ref.get () in
  Domain_pool_ref.clear_for_tests ();
  Fun.protect
    ~finally:(fun () -> Option.iter Domain_pool_ref.set previous)
    f

let test_without_a_pool_the_work_stays_on_the_callers_domain () =
  Eio_main.run (fun _env ->
    without_pool (fun () ->
      let caller = domain_id () in
      Alcotest.(check int) "the caller's domain" caller (Index.blocking domain_id)))

let test_with_a_pool_the_work_leaves_the_callers_domain () =
  Eio_main.run (fun env ->
    with_pool env (fun () ->
      let caller = domain_id () in
      let worker = Index.blocking domain_id in
      Alcotest.(check bool) "another domain" true (worker <> caller)))

let test_a_pool_job_keeps_the_work_in_its_domain () =
  Eio_main.run (fun env ->
    with_pool env (fun () ->
      let job_domain, work_domain =
        Domain_pool_ref.submit_cpu_or_inline ~name:__FUNCTION__ (fun () ->
          domain_id (), Index.blocking domain_id)
      in
      Alcotest.(check int) "the job's domain" job_domain work_domain))

(* The index's file helpers rely on running outside Eio: Fs_compat then takes
   its synchronous path, and the store mutex is never taken on a scheduler
   thread. Moving the work to a pool domain keeps it in a system thread. *)
let test_the_work_runs_outside_eio () =
  let outside_eio () =
    match Fs_compat.execution_context () with
    | Fs_compat.Non_eio -> true
    | Fs_compat.Eio_fiber -> false
  in
  Eio_main.run (fun env ->
    without_pool (fun () ->
      Alcotest.(check bool) "without a pool" true (Index.blocking outside_eio));
    with_pool env (fun () ->
      Alcotest.(check bool) "with a pool" true (Index.blocking outside_eio)))

exception Raised_in_the_work

let test_an_exception_reaches_the_caller () =
  Eio_main.run (fun env ->
    with_pool env (fun () ->
      Alcotest.check_raises "the work's exception" Raised_in_the_work (fun () ->
        Index.blocking (fun () -> raise Raised_in_the_work))))

let () =
  Alcotest.run "keeper_tool_call_index_domain"
    [
      ( "domain",
        [
          Alcotest.test_case "without a pool the work stays on the caller's domain" `Quick
            test_without_a_pool_the_work_stays_on_the_callers_domain;
          Alcotest.test_case "with a pool the work leaves the caller's domain" `Quick
            test_with_a_pool_the_work_leaves_the_callers_domain;
          Alcotest.test_case "a pool job keeps the work in its domain" `Quick
            test_a_pool_job_keeps_the_work_in_its_domain;
          Alcotest.test_case "the work runs outside Eio" `Quick
            test_the_work_runs_outside_eio;
          Alcotest.test_case "an exception reaches the caller" `Quick
            test_an_exception_reaches_the_caller;
        ] );
    ]
