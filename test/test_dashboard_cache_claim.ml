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

let lookup ?(timeout_sec = 5.) ~clock key compute =
  Dashboard_cache.get_or_compute_with_timeout key ~ttl:60. ~clock ~timeout_sec
    (Pool_work.cpu ~name:__FUNCTION__ compute)
;;

(* A cached value, read without computing. *)
let cached ~clock key = lookup ~clock key (fun () -> failwith "the key was not cached")

(* Start a pool job that runs [body] once [go] resolves. Unless [queued],
   wait until it holds a worker. *)
let start_job ?(queued = false) ~sw ~go body =
  let on_worker, arrived = Eio.Promise.create () in
  let result =
    Eio.Fiber.fork_promise ~sw (fun () ->
      Executor_pool_ref.submit_or_inline ~name:__FUNCTION__ (fun () ->
        Eio.Promise.resolve arrived ();
        Eio.Promise.await go;
        body ()))
  in
  if not queued then Eio.Promise.await on_worker;
  result
;;

let start_waiter ?queued ?timeout_sec ~sw ~clock ~go key compute =
  start_job ?queued ~sw ~go (fun () -> lookup ?timeout_sec ~clock key compute)
;;

(* A compute that says when it starts running, so a test knows its claim is
   taken, and then holds until finished. *)
let held_compute value =
  let running, started = Eio.Promise.create () in
  let finish, finished = Eio.Promise.create () in
  let compute () =
    Eio.Promise.resolve started ();
    Eio.Promise.await finish;
    value
  in
  compute, running, fun () -> Eio.Promise.resolve finished ()
;;

(* A compute that never returns. *)
let stuck () =
  let never, _ = Eio.Promise.create () in
  Eio.Promise.await never
;;

(* A job that holds a worker until released. *)
let hold_worker ?queued ~sw () =
  let release, released = Eio.Promise.create () in
  let go, start = Eio.Promise.create () in
  let job = start_job ?queued ~sw ~go (fun () -> Eio.Promise.await release) in
  Eio.Promise.resolve start ();
  fun () ->
    Eio.Promise.resolve released ();
    ignore (Eio.Promise.await_exn job)
;;

(* Start the owner outside the pool. Its fork runs until its compute is
   queued, so the Computing slot exists when this returns. *)
let start_owner ?timeout_sec ~sw ~clock key compute =
  Eio.Fiber.fork_promise ~sw (fun () -> lookup ?timeout_sec ~clock key compute)
;;

let within ~clock what f =
  match Eio.Time.with_timeout clock 3. (fun () -> Ok (f ())) with
  | Ok value -> value
  | Error `Timeout -> fail what
;;

let counted runs value () =
  Atomic.incr runs;
  value
;;

(* The only worker is held by a job that waits for the key, and the owner's
   compute is queued behind it. The waiting job claims and runs it and
   publishes it; the owner's job finds the claim taken and does not compute. *)
let test_a_waiting_job_runs_the_compute_queued_behind_it () =
  with_pool ~domain_count:1 (fun ~sw ~clock ->
    let key = "claim-inversion" in
    let owner_runs = Atomic.make 0 in
    let waiter_runs = Atomic.make 0 in
    let go, start = Eio.Promise.create () in
    let waiter = start_waiter ~sw ~clock ~go key (counted waiter_runs (`String "computed")) in
    let owner = start_owner ~sw ~clock key (counted owner_runs (`String "computed")) in
    Eio.Promise.resolve start ();
    let waited, owned =
      within ~clock "the waiting job held the only worker" (fun () ->
        Eio.Promise.await_exn waiter, Eio.Promise.await_exn owner)
    in
    check json "the waiting job got the value" (`String "computed") waited;
    check json "the owner got the value" (`String "computed") owned;
    check int "the waiting job computed once" 1 (Atomic.get waiter_runs);
    check int "the owner's job did not compute" 0 (Atomic.get owner_runs);
    check json "the value is cached" (`String "computed") (cached ~clock key))
;;

(* The owner returns once the claim is settled, even while its own job is
   still queued behind other work. *)
let test_an_owner_returns_while_its_job_is_still_queued () =
  with_pool ~domain_count:2 (fun ~sw ~clock ->
    let key = "claim-owner-queued" in
    let go, start = Eio.Promise.create () in
    let waiter = start_waiter ~sw ~clock ~go key (fun () -> `String "computed") in
    let release_second_worker = hold_worker ~sw () in
    let release_queued = hold_worker ~queued:true ~sw () in
    let owner = start_owner ~sw ~clock key (fun () -> `String "owner") in
    Eio.Promise.resolve start ();
    let owned =
      within ~clock "the owner waited for its queued job" (fun () -> Eio.Promise.await_exn owner)
    in
    check json "the owner got the claimant's value" (`String "computed") owned;
    ignore (Eio.Promise.await_exn waiter);
    release_second_worker ();
    release_queued ())
;;

(* The owner's job reaches a second worker while the claimant still runs the
   compute. It finds the claim taken and returns without computing. *)
let test_an_owner_job_that_lost_the_claim_does_not_compute () =
  with_pool ~domain_count:2 (fun ~sw ~clock ->
    let key = "claim-owner-job-lost" in
    let owner_runs = Atomic.make 0 in
    let go, start = Eio.Promise.create () in
    let compute, running, finish = held_compute (`String "claimant") in
    let claimant = start_waiter ~sw ~clock ~go key compute in
    let release_second_worker = hold_worker ~sw () in
    let owner = start_owner ~sw ~clock key (counted owner_runs (`String "owner")) in
    Eio.Promise.resolve start ();
    Eio.Promise.await running;
    (* The owner's job takes the second worker while the claim is held. *)
    release_second_worker ();
    Eio.Time.sleep clock 0.1;
    finish ();
    let claimed, owned =
      within ~clock "the claim did not settle" (fun () ->
        Eio.Promise.await_exn claimant, Eio.Promise.await_exn owner)
    in
    check json "the claimant got its value" (`String "claimant") claimed;
    check json "the owner got the claimant's value" (`String "claimant") owned;
    check int "the owner's job did not compute" 0 (Atomic.get owner_runs))
;;

(* The claimant's compute fails while a second waiting job is queued ahead of
   the owner's job. The key is freed at once: the second job computes it
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

(* The claimant's request gives up mid-compute. The owner does not fail for
   it: the slot is cleared and the owner computes the key itself. *)
let test_a_cancelled_claim_makes_the_owner_compute () =
  with_pool ~domain_count:1 (fun ~sw ~clock ->
    let key = "claim-cancelled" in
    let owner_runs = Atomic.make 0 in
    let go, start = Eio.Promise.create () in
    let give_up, gave_up = Eio.Promise.create () in
    let compute, running, _finish = held_compute (`String "never") in
    let claimant =
      start_job ~sw ~go (fun () ->
        Eio.Fiber.first
          (fun () -> lookup ~clock key compute)
          (fun () ->
            Eio.Promise.await give_up;
            `String "gave up"))
    in
    let owner = start_owner ~sw ~clock key (counted owner_runs (`String "owner")) in
    Eio.Promise.resolve start ();
    Eio.Promise.await running;
    Eio.Promise.resolve gave_up ();
    let given_up, owned =
      within ~clock "the owner waited after the claimant gave up" (fun () ->
        Eio.Promise.await_exn claimant, Eio.Promise.await owner)
    in
    check json "the claimant's request gave up" (`String "gave up") given_up;
    check bool "the owner computed the key" true (owned = Ok (`String "owner"));
    check int "the owner's compute ran once" 1 (Atomic.get owner_runs))
;;

(* The owner's window closes while a claimant still computes. The slot stays
   with the claimant, which publishes; the key is not computed again. *)
let test_an_owner_that_gives_up_leaves_the_claim_to_its_claimant () =
  with_pool ~domain_count:1 (fun ~sw ~clock ->
    let key = "claim-owner-timeout" in
    let go, start = Eio.Promise.create () in
    let compute, running, finish = held_compute (`String "claimant") in
    let claimant = start_waiter ~sw ~clock ~go key compute in
    let owner = start_owner ~timeout_sec:1.0 ~sw ~clock key (fun () -> `String "owner") in
    Eio.Promise.resolve start ();
    Eio.Promise.await running;
    let owned =
      within ~clock "the owner's window did not close" (fun () -> Eio.Promise.await_exn owner)
    in
    check bool "the owner got a timeout" true (Dashboard_cache.is_timeout_envelope owned);
    finish ();
    let claimed =
      within ~clock "the claimant did not finish" (fun () -> Eio.Promise.await_exn claimant)
    in
    check json "the claimant got its value" (`String "claimant") claimed;
    check json "the claimant's value is cached" (`String "claimant") (cached ~clock key))
;;

(* The owner's window closes before anyone claimed its compute. It abandons
   the compute and frees the key, so the next lookup computes at once. *)
let test_an_owner_that_gives_up_first_frees_the_key () =
  with_pool ~domain_count:1 (fun ~sw ~clock ->
    let key = "claim-abandoned" in
    let release = hold_worker ~sw () in
    let owner = start_owner ~timeout_sec:0.3 ~sw ~clock key (fun () -> `String "owner") in
    let owned =
      within ~clock "the owner's window did not close" (fun () -> Eio.Promise.await_exn owner)
    in
    check bool "the owner got a timeout" true (Dashboard_cache.is_timeout_envelope owned);
    release ();
    let next =
      within ~clock "the abandoned key was still computing" (fun () ->
        lookup ~clock key (fun () -> `String "next"))
    in
    check json "the next lookup computes" (`String "next") next)
;;

(* The claimant's own window closes mid-compute. The owner does not take that
   as a failure: it computes the key itself. *)
let test_a_claim_whose_window_closes_makes_the_owner_compute () =
  with_pool ~domain_count:1 (fun ~sw ~clock ->
    let key = "claim-window" in
    let owner_runs = Atomic.make 0 in
    let go, start = Eio.Promise.create () in
    let claimant = start_waiter ~timeout_sec:0.3 ~sw ~clock ~go key stuck in
    let owner = start_owner ~sw ~clock key (counted owner_runs (`String "owner")) in
    Eio.Promise.resolve start ();
    let claimed, owned =
      within ~clock "the owner waited after the claimant's window closed" (fun () ->
        Eio.Promise.await_exn claimant, Eio.Promise.await owner)
    in
    check bool "the claimant's window closed" true (Dashboard_cache.is_timeout_envelope claimed);
    check bool "the owner computed the key" true (owned = Ok (`String "owner"));
    check int "the owner's compute ran once" 1 (Atomic.get owner_runs))
;;

(* A retry after a released claim stays inside the owner's window: the owner
   times out when its own window closes, not a full window after the retry. *)
let test_a_retry_keeps_the_owners_window () =
  with_pool ~domain_count:1 (fun ~sw ~clock ->
    let key = "claim-retry-window" in
    let go, start = Eio.Promise.create () in
    let claimant = start_waiter ~timeout_sec:0.4 ~sw ~clock ~go key stuck in
    let started_at = Eio.Time.now clock in
    let owner = start_owner ~timeout_sec:1.0 ~sw ~clock key stuck in
    Eio.Promise.resolve start ();
    let owned = within ~clock "the owner never timed out" (fun () -> Eio.Promise.await_exn owner) in
    let elapsed = Eio.Time.now clock -. started_at in
    ignore (Eio.Promise.await claimant);
    check bool "the owner timed out" true (Dashboard_cache.is_timeout_envelope owned);
    check bool (Printf.sprintf "within its own window (%.2fs)" elapsed) true (elapsed < 1.3))
;;

(* A claimant publishes only into the epoch it claimed. The key was
   invalidated and is being computed again when it finishes. *)
let test_a_claimant_does_not_publish_into_a_newer_epoch () =
  with_pool ~domain_count:1 (fun ~sw ~clock ->
    let key = "claim-epoch" in
    let go, start = Eio.Promise.create () in
    let compute, running, finish = held_compute (`String "old epoch") in
    let claimant = start_waiter ~sw ~clock ~go key compute in
    let first_owner = start_owner ~sw ~clock key (fun () -> `String "first owner") in
    Eio.Promise.resolve start ();
    Eio.Promise.await running;
    Dashboard_cache.invalidate_all ();
    let second_owner = start_owner ~sw ~clock key (fun () -> `String "new epoch") in
    finish ();
    let _ =
      within ~clock "the old epoch did not finish" (fun () ->
        Eio.Promise.await_exn claimant, Eio.Promise.await_exn first_owner)
    in
    let renewed =
      within ~clock "the new epoch did not finish" (fun () -> Eio.Promise.await_exn second_owner)
    in
    check json "the new epoch's owner got its value" (`String "new epoch") renewed;
    check json "the new epoch's value is cached" (`String "new epoch") (cached ~clock key))
;;

(* A lookup outside the pool holds no worker, so it waits instead of
   claiming. *)
let test_a_fiber_outside_the_pool_does_not_claim () =
  with_pool ~domain_count:1 (fun ~sw ~clock ->
    let key = "claim-outside-pool" in
    let waiter_runs = Atomic.make 0 in
    let release = hold_worker ~sw () in
    let owner = start_owner ~sw ~clock key (fun () -> `String "owner") in
    let waiter =
      Eio.Fiber.fork_promise ~sw (fun () ->
        lookup ~clock key (counted waiter_runs (`String "waiter")))
    in
    Eio.Time.sleep clock 0.1;
    release ();
    let waited, owned =
      within ~clock "the owner's job did not run" (fun () ->
        Eio.Promise.await_exn waiter, Eio.Promise.await_exn owner)
    in
    check json "the owner computed" (`String "owner") owned;
    check json "the outside lookup got the owner's value" (`String "owner") waited;
    check int "the outside lookup did not compute" 0 (Atomic.get waiter_runs))
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
    let waiter = start_waiter ~sw ~clock ~go key (counted runs (`String "waiter")) in
    Eio.Promise.resolve start ();
    (* Let the job look the key up while the compute still runs. *)
    Eio.Time.sleep clock 0.1;
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
        ; test_case "an owner returns while its job is still queued" `Quick
            test_an_owner_returns_while_its_job_is_still_queued
        ; test_case "an owner job that lost the claim does not compute" `Quick
            test_an_owner_job_that_lost_the_claim_does_not_compute
        ; test_case "a failed claim frees the key and fails the owner" `Quick
            test_a_failed_claim_frees_the_key_and_fails_the_owner
        ; test_case "a cancelled claim makes the owner compute" `Quick
            test_a_cancelled_claim_makes_the_owner_compute
        ; test_case "an owner that gives up leaves the claim to its claimant" `Quick
            test_an_owner_that_gives_up_leaves_the_claim_to_its_claimant
        ; test_case "an owner that gives up first frees the key" `Quick
            test_an_owner_that_gives_up_first_frees_the_key
        ; test_case "a claim whose window closes makes the owner compute" `Quick
            test_a_claim_whose_window_closes_makes_the_owner_compute
        ; test_case "a retry keeps the owner's window" `Quick
            test_a_retry_keeps_the_owners_window
        ; test_case "a claimant does not publish into a newer epoch" `Quick
            test_a_claimant_does_not_publish_into_a_newer_epoch
        ; test_case "a fiber outside the pool does not claim" `Quick
            test_a_fiber_outside_the_pool_does_not_claim
        ; test_case "a job waits for a running compute" `Quick
            test_a_job_waits_for_a_running_compute
        ] )
    ]
;;
