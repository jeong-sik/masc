open Alcotest

(* RFC-0204 §3.4 L4b. One pool, as small as the read pool can be. The owner
   is a fiber outside the pool whose compute is a pool job; a waiter is a pool
   job that looks the same key up. *)

let with_pool ~domain_count f =
  Eio_main.run (fun env ->
    Eio_guard.enable ();
    Eio.Switch.run (fun sw ->
      let clock = Eio.Stdenv.clock env in
      Eio_context.set_switch sw;
      (* A waiting lookup polls with [Time_compat.sleep]. *)
      Time_compat.set_clock clock;
      let pool = Domain_pool.create ~sw ~domain_count (Eio.Stdenv.domain_mgr env) in
      Domain_pool_ref.set pool;
      Fun.protect
        ~finally:(fun () ->
          Domain_pool_ref.clear_for_tests ();
          Eio_context.For_testing.clear_root_switch ())
        (fun () ->
          Executor_pool_ref.For_testing.with_pool (Domain_pool.executor_pool pool) (fun () ->
            Dashboard_cache.invalidate_all ();
            f ~sw ~clock))))
;;

let json = testable (Fmt.of_to_string Yojson.Safe.to_string) Yojson.Safe.equal
let lookup ~clock key compute =
  Dashboard_cache.get_or_compute_with_timeout key ~ttl:60. ~clock ~timeout_sec:5. compute
;;

(* Start a pool job that looks [key] up once [go] resolves. Unless [queued],
   wait until it holds a worker. *)
let start_waiter ?(queued = false) ~sw ~clock ~go key compute =
  let on_worker, arrived = Eio.Promise.create () in
  let result =
    Eio.Fiber.fork_promise ~sw (fun () ->
      Executor_pool_ref.submit_or_inline (fun () ->
        Eio.Promise.resolve arrived ();
        Eio.Promise.await go;
        lookup ~clock key compute))
  in
  if not queued then Eio.Promise.await on_worker;
  result
;;

(* Start the owner outside the pool. Its fork runs until its compute is
   queued, so the Computing slot exists when this returns. *)
let start_owner ~sw ~clock key compute =
  Eio.Fiber.fork_promise ~sw (fun () -> lookup ~clock key compute)
;;

let within ~clock what f =
  match Eio.Time.with_timeout clock 3. (fun () -> Ok (f ())) with
  | Ok value -> value
  | Error `Timeout -> fail what
;;

(* The only worker is held by a job that waits for the key, and the owner's
   compute is queued behind it. The waiting job claims and runs it; the
   owner's job then finds the claim taken and does not compute. *)
let test_a_waiting_job_runs_the_compute_queued_behind_it () =
  with_pool ~domain_count:1 (fun ~sw ~clock ->
    let key = "claim-inversion" in
    let owner_runs = Atomic.make 0 in
    let waiter_runs = Atomic.make 0 in
    let go, start = Eio.Promise.create () in
    let waiter =
      start_waiter ~sw ~clock ~go key (fun () ->
        Atomic.incr waiter_runs;
        `String "computed")
    in
    let owner =
      start_owner ~sw ~clock key (fun () ->
        Atomic.incr owner_runs;
        `String "computed")
    in
    Eio.Promise.resolve start ();
    let waited, owned =
      within ~clock "the waiting job held the only worker" (fun () ->
        Eio.Promise.await_exn waiter, Eio.Promise.await_exn owner)
    in
    check json "the waiting job got the value" (`String "computed") waited;
    check json "the owner got the value" (`String "computed") owned;
    check int "the waiting job computed once" 1 (Atomic.get waiter_runs);
    check int "the owner's job did not compute" 0 (Atomic.get owner_runs))
;;

(* The claimant's compute fails while a second waiting job is queued ahead
   of the owner's job. The key is freed at once: the second job computes it
   instead of holding the only worker for a slot nobody will fill. The owner
   gets the claimant's failure. *)
let test_a_failed_claim_frees_the_key_and_fails_the_owner () =
  with_pool ~domain_count:1 (fun ~sw ~clock ->
    let key = "claim-failure" in
    let go, start = Eio.Promise.create () in
    let claimant = start_waiter ~sw ~clock ~go key (fun () -> failwith "claimant failed") in
    let next = start_waiter ~queued:true ~sw ~clock ~go key (fun () -> `String "next") in
    let owner = start_owner ~sw ~clock key (fun () -> `String "owner") in
    Eio.Promise.resolve start ();
    let claimed, recomputed, owned =
      within ~clock "a job waited on the failed claim" (fun () ->
        Eio.Promise.await claimant, Eio.Promise.await next, Eio.Promise.await owner)
    in
    let failed = function
      | Error (Failure message) -> message = "claimant failed"
      | Ok _ | Error _ -> false
    in
    check bool "the claimant got its failure" true (failed claimed);
    check bool "the next job computed the key itself" true (recomputed = Ok (`String "next"));
    check bool "the owner got the claimant's failure" true (failed owned))
;;

(* The owner's job is already computing on one worker. A job on the other
   worker waits for it instead of computing again. *)
let test_a_job_waits_for_a_running_compute () =
  with_pool ~domain_count:2 (fun ~sw ~clock ->
    let key = "claim-running" in
    let runs = Atomic.make 0 in
    let running, started = Eio.Promise.create () in
    let release, finish = Eio.Promise.create () in
    let owner =
      start_owner ~sw ~clock key (fun () ->
        Atomic.incr runs;
        Eio.Promise.resolve started ();
        Eio.Promise.await release;
        `String "owner")
    in
    Eio.Promise.await running;
    let go, start = Eio.Promise.create () in
    let waiter =
      start_waiter ~sw ~clock ~go key (fun () ->
        Atomic.incr runs;
        `String "waiter")
    in
    Eio.Promise.resolve start ();
    Eio.Promise.resolve finish ();
    let waited, owned =
      within ~clock "the compute did not finish" (fun () ->
        Eio.Promise.await_exn waiter, Eio.Promise.await_exn owner)
    in
    check json "the owner got its value" (`String "owner") owned;
    check json "the waiting job got the owner's value" (`String "owner") waited;
    check int "the compute ran once" 1 (Atomic.get runs))
;;

let () =
  run "Dashboard_cache claim"
    [ ( "rfc-0204 3.4 L4b"
      , [ test_case "a waiting job runs the compute queued behind it" `Quick
            test_a_waiting_job_runs_the_compute_queued_behind_it
        ; test_case "a failed claim frees the key and fails the owner" `Quick
            test_a_failed_claim_frees_the_key_and_fails_the_owner
        ; test_case "a job waits for a running compute" `Quick
            test_a_job_waits_for_a_running_compute
        ] )
    ]
;;
