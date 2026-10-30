open Alcotest

(** Unit tests for [Domain_pool] — RFC-0059 Phase 2 PR-6.

    Each test runs inside [Eio_main.run] + [Eio.Switch.run] because
    [Domain_pool.create] requires an active switch and a real
    [Eio.Domain_manager.t] from [Eio.Stdenv].  Worker domains are torn
    down when the switch finishes — every test is isolated. *)

module D = Domain_pool
module R = Domain_pool_ref

(* ── recommended_domain_count ──────────────────────────── *)

let test_recommended_domain_count_floor () =
  let n = D.recommended_domain_count () in
  check bool "at least one worker domain" true (n >= 1)

let test_recommended_domain_count_reserves_scheduler_headroom () =
  (* Keep the pool below OCaml's recommended domain count so the main Eio
     scheduler and response finalisation do not compete with a saturated
     executor pool.  On tiny hosts, preserve one worker domain. *)
  let raw = Domain.recommended_domain_count () in
  let ours = D.recommended_domain_count () in
  if raw >= 3 then check int "subtract scheduler headroom" (raw - 2) ours
  else
    check bool "floor applies on small hosts" true (ours = 1)

(* ── create ────────────────────────────────────────────── *)

let test_create_default () =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      let dm = Eio.Stdenv.domain_mgr env in
      let pool = D.create ~sw dm in
      check int "default count matches recommended"
        (D.recommended_domain_count ()) (D.domain_count pool)))

let test_create_explicit () =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      let dm = Eio.Stdenv.domain_mgr env in
      let pool = D.create ~sw ~domain_count:1 dm in
      check int "explicit count honoured" 1 (D.domain_count pool)))

let test_create_zero_rejected () =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      let dm = Eio.Stdenv.domain_mgr env in
      check_raises "zero domain_count raises Invalid_argument"
        (Invalid_argument
           "Domain_pool.create: domain_count must be >= 1, got 0")
        (fun () -> ignore (D.create ~sw ~domain_count:0 dm))))

let test_create_negative_rejected () =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      let dm = Eio.Stdenv.domain_mgr env in
      check_raises "negative domain_count raises Invalid_argument"
        (Invalid_argument
           "Domain_pool.create: domain_count must be >= 1, got -2")
        (fun () -> ignore (D.create ~sw ~domain_count:(-2) dm))))

(* ── submit ────────────────────────────────────────────── *)

let test_submit_cpu_returns_value () =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      let dm = Eio.Stdenv.domain_mgr env in
      let pool = D.create ~sw ~domain_count:1 dm in
      let result = D.submit_cpu ~name:__FUNCTION__ pool (fun () -> 1 + 2) in
      check int "blocking cpu submit returns value" 3 result))

let test_submit_io_returns_value () =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      let dm = Eio.Stdenv.domain_mgr env in
      let pool = D.create ~sw ~domain_count:1 dm in
      let result = D.submit_io ~name:__FUNCTION__ pool (fun () -> "hello") in
      check string "blocking io submit returns value" "hello" result))

let test_submit_cpu_propagates_exception () =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      let dm = Eio.Stdenv.domain_mgr env in
      let pool = D.create ~sw ~domain_count:1 dm in
      check_raises "cpu submit re-raises handler exception"
        (Failure "boom")
        (fun () -> D.submit_cpu ~name:__FUNCTION__ pool (fun () -> failwith "boom"))))

(* ── async submit ──────────────────────────────────────── *)

let test_submit_cpu_async_resolves () =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      let dm = Eio.Stdenv.domain_mgr env in
      let pool = D.create ~sw ~domain_count:1 dm in
      let promise = D.submit_cpu_async ~name:__FUNCTION__ ~sw pool (fun () -> 42) in
      check int "async cpu promise resolves" 42
        (Eio.Promise.await_exn promise)))

let test_submit_io_async_resolves () =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      let dm = Eio.Stdenv.domain_mgr env in
      let pool = D.create ~sw ~domain_count:1 dm in
      let promise = D.submit_io_async ~name:__FUNCTION__ ~sw pool (fun () -> "ok") in
      check string "async io promise resolves" "ok"
        (Eio.Promise.await_exn promise)))

let test_submit_async_propagates_exception () =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      let dm = Eio.Stdenv.domain_mgr env in
      let pool = D.create ~sw ~domain_count:1 dm in
      let promise = D.submit_cpu_async ~name:__FUNCTION__ ~sw pool (fun () -> failwith "boom") in
      check_raises "async submit propagates exception"
        (Failure "boom")
        (fun () -> ignore (Eio.Promise.await_exn promise))))

(* ── multi-domain dispatch ──────────────────────────────── *)

(* [Gc.set]'s minor_heap_size is per-domain in OCaml 5, so tuning it on the
   main domain leaves every later one at the 2 MB default. That is not only a
   frequency: a minor collection is a stop-the-world barrier across all
   domains, so a pool domain collecting eight times as often stops the whole
   process that much more. *)
let test_pool_work_runs_on_the_tuned_minor_heap () =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      let dm = Eio.Stdenv.domain_mgr env in
      let pool = D.create ~sw ~domain_count:2 dm in
      let main_domain = (Domain.self () :> int) in
      let where, words =
        D.submit_cpu ~name:__FUNCTION__ pool (fun () ->
          (Domain.self () :> int), (Gc.get ()).Gc.minor_heap_size)
      in
      check bool "the job did run off the main domain" true (where <> main_domain);
      check bool
        (Printf.sprintf "the worker's minor heap is the tuned size, got %d words" words)
        true
        (words >= 4 * 1024 * 1024)))
;;

let test_jobs_run_on_worker_domains () =
  (* The submitting fiber runs on the main Domain.  Jobs submitted to
     a 2-domain pool must execute on a different Domain.  We don't
     assert which worker (Eio chooses), only that it is not the
     main. *)
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      let dm = Eio.Stdenv.domain_mgr env in
      let pool = D.create ~sw ~domain_count:2 dm in
      let main_domain = (Domain.self () :> int) in
      let worker_domain =
        D.submit_cpu ~name:__FUNCTION__ pool (fun () -> (Domain.self () :> int))
      in
      check bool "worker job runs off main domain" true
        (worker_domain <> main_domain)))

(* ── escape hatch ──────────────────────────────────────── *)

let test_executor_pool_accessor () =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      let dm = Eio.Stdenv.domain_mgr env in
      let pool = D.create ~sw ~domain_count:1 dm in
      let raw = D.executor_pool pool in
      let result =
        Eio.Executor_pool.submit_exn raw ~weight:0.5 (fun () -> "via_raw")
      in
      check string "executor_pool exposes underlying pool" "via_raw" result))

(* ── process-wide reference ────────────────────────────── *)

let test_ref_runs_inline_when_absent () =
  R.clear_for_tests ();
  let main_domain = (Domain.self () :> int) in
  let observed = R.submit_cpu_or_inline ~name:__FUNCTION__ (fun () -> (Domain.self () :> int)) in
  check int "absent pool runs inline" main_domain observed

let test_ref_submits_to_shared_pool () =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      R.clear_for_tests ();
      let dm = Eio.Stdenv.domain_mgr env in
      let pool = D.create ~sw ~domain_count:1 dm in
      R.set pool;
      check (option int) "domain count exposed" (Some 1) (R.domain_count_opt ());
      let main_domain = (Domain.self () :> int) in
      let worker_domain =
        R.submit_cpu_or_inline ~name:__FUNCTION__ (fun () -> (Domain.self () :> int))
      in
      check bool "ref submit runs off main domain" true
        (worker_domain <> main_domain);
      R.clear_for_tests ()))

let test_keeper_model_input_projection_uses_shared_pool () =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      let previous = R.get () in
      Eio.Switch.on_release sw (fun () ->
        match previous with
        | None -> R.clear_for_tests ()
        | Some pool -> R.set pool);
      let pool =
        D.create ~sw ~domain_count:1 (Eio.Stdenv.domain_mgr env)
      in
      R.set pool;
      let caller_domain = Domain.self () in
      let projection_domain =
        Masc.Keeper_turn_driver_try_provider.For_testing
        .offload_model_input_cpu Domain.self
      in
      check bool "Keeper model-input CPU work leaves the Eio domain" true
        (projection_domain <> caller_domain)))

(* A job that submits again through the process-wide ref, as store code
   reached from inside pool work does. The inner submit runs inline on the
   outer job's worker. Before, it queued behind the outer job on the only
   worker, which waited for it forever; the deadline turns that hang into a
   failure. *)
let nested_submit_deadline_s = 10.0

let test_a_job_that_submits_again_runs_the_inner_work_on_its_worker () =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      R.clear_for_tests ();
      let dm = Eio.Stdenv.domain_mgr env in
      let pool = D.create ~sw ~domain_count:1 dm in
      R.set pool;
      Fun.protect ~finally:R.clear_for_tests (fun () ->
        let within_deadline f =
          Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) nested_submit_deadline_s f
        in
        let nested () =
          let outer = (Domain.self () :> int) in
          outer, R.submit_cpu_or_inline ~name:__FUNCTION__ (fun () -> (Domain.self () :> int))
        in
        let outer, inner = within_deadline (fun () -> D.submit_cpu ~name:__FUNCTION__ pool nested) in
        check int "a cpu job's inner submit runs on its worker" outer inner;
        let outer, inner =
          within_deadline (fun () ->
            Eio.Promise.await_exn (D.submit_io_async ~name:__FUNCTION__ ~sw pool nested))
        in
        check int "an async io job's inner submit runs on its worker" outer inner)))

(* A worker runs several jobs at once -- an IO job weighs a twentieth of it --
   and they end in any order. Job A starts, job B starts on the same worker,
   and A ends while B still runs: B is still pool work, so its own submit
   stays inline on its worker instead of queueing behind the capacity it
   holds. *)
let test_a_job_still_running_after_another_ends_is_pool_work () =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      R.clear_for_tests ();
      let pool = D.create ~sw ~domain_count:1 (Eio.Stdenv.domain_mgr env) in
      R.set pool;
      Fun.protect ~finally:R.clear_for_tests (fun () ->
        let a_started, a_started_u = Eio.Promise.create () in
        let a_release, a_release_u = Eio.Promise.create () in
        let b_started, b_started_u = Eio.Promise.create () in
        let b_check, b_check_u = Eio.Promise.create () in
        let a =
          D.submit_io_async ~name:__FUNCTION__ ~sw pool (fun () ->
            Eio.Promise.resolve a_started_u ();
            Eio.Promise.await a_release)
        in
        Eio.Promise.await a_started;
        let b =
          D.submit_io_async ~name:__FUNCTION__ ~sw pool (fun () ->
            Eio.Promise.resolve b_started_u ();
            Eio.Promise.await b_check;
            Executor_pool_ref.in_worker_context ())
        in
        Eio.Promise.await b_started;
        Eio.Promise.resolve a_release_u ();
        Eio.Promise.await_exn a;
        Eio.Promise.resolve b_check_u ();
        check bool "the job still running is pool work" true (Eio.Promise.await_exn b))))

let test_ref_inline_from_raw_domain_with_pool () =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      R.clear_for_tests ();
      let dm = Eio.Stdenv.domain_mgr env in
      let pool = D.create ~sw ~domain_count:1 dm in
      R.set pool;
      (* A raw Domain has no Eio effect handler, so a pool submit from it
         would raise [Effect.Unhandled]. With the pool installed, the ref
         must detect the non-Eio caller and run inline in that caller's own
         domain (#25158). *)
      let raw =
        Domain.spawn (fun () ->
          let self = (Domain.self () :> int) in
          let observed =
            R.submit_cpu_or_inline ~name:__FUNCTION__ (fun () -> (Domain.self () :> int))
          in
          (self, observed))
      in
      let self, observed = Domain.join raw in
      check int "raw-domain caller runs inline in its own domain" self observed;
      R.clear_for_tests ()))

exception Stop_pool_submission

type submission_shape = Blocking_io | Blocking_cpu | Async_io | Async_cpu
  | Shared_executor | Strict_executor

let submission_shapes = [Blocking_io;Blocking_cpu;Async_io;Async_cpu;Shared_executor;Strict_executor]

let submission_name = function
  | Blocking_io -> "blocking IO" | Blocking_cpu -> "blocking CPU"
  | Async_io -> "async IO" | Async_cpu -> "async CPU"
  | Shared_executor -> "shared executor" | Strict_executor -> "strict executor"

let run_unit_submission shape ~sw pool operation = match shape with
  | Blocking_io -> D.submit_io ~name:__FUNCTION__ pool operation
  | Blocking_cpu -> D.submit_cpu ~name:__FUNCTION__ pool operation
  | Async_io -> Eio.Promise.await_exn (D.submit_io_async ~name:__FUNCTION__ ~sw pool operation)
  | Async_cpu -> Eio.Promise.await_exn (D.submit_cpu_async ~name:__FUNCTION__ ~sw pool operation)
  | Shared_executor -> Executor_pool_ref.submit_or_inline ~name:__FUNCTION__ operation
  | Strict_executor ->
    (match Executor_pool_ref.submit_strict ~name:__FUNCTION__ operation with
     | Ok () -> ()
     | Error (Executor_pool_ref.Work_failed (error,backtrace)) ->
       Printexc.raise_with_backtrace error backtrace
     | Error (Executor_pool_ref.Pool_unavailable | Caller_not_in_eio | Submission_failed _) ->
       fail "strict executor did not preserve the submission boundary")

let with_submission_pool f =
  Eio_main.run (fun env -> Eio.Switch.run (fun sw ->
    let pool = D.create ~sw ~domain_count:1 (Eio.Stdenv.domain_mgr env) in
    Executor_pool_ref.For_testing.with_pool (D.executor_pool pool) (fun () -> f ~sw pool)))

let test_cancelled_submission_joins_worker_cleanup shape () =
  with_submission_pool (fun ~sw pool ->
    let sibling_started,sibling_started_u = Eio.Promise.create () in
    let sibling_release,sibling_release_u = Eio.Promise.create () in
    let worker_started,worker_started_u = Eio.Promise.create () in
    let cleanup_started,cleanup_started_u = Eio.Promise.create () in
    let cleanup_release,cleanup_release_u = Eio.Promise.create () in
    let owner_switch,owner_switch_u = Eio.Promise.create () in
    let entered = Atomic.make 0 in
    let cleaned = Atomic.make false in
    Fun.protect ~finally:(fun () ->
      ignore (Eio.Promise.try_resolve sibling_release_u ());
      ignore (Eio.Promise.try_resolve cleanup_release_u ())) (fun () ->
      (* Admit the sibling before a full-weight CPU invocation. It must keep
         running even while the other invocation's cleanup is held. *)
      let sibling = D.submit_io_async ~name:__FUNCTION__ ~sw pool (fun () ->
        Eio.Promise.resolve sibling_started_u ();
        Eio.Promise.await sibling_release;
        "independent sibling") in
      Eio.Promise.await sibling_started;
      let owner = Eio.Fiber.fork_promise ~sw (fun () ->
        match Eio.Switch.run (fun owner_sw ->
          Eio.Promise.resolve owner_switch_u owner_sw;
          run_unit_submission shape ~sw:owner_sw pool (fun () ->
            ignore (Atomic.fetch_and_add entered 1);
            Eio.Switch.run (fun worker_sw ->
              Eio.Switch.on_release worker_sw (fun () ->
                Eio.Promise.resolve cleanup_started_u ();
                Eio.Promise.await cleanup_release;
                Atomic.set cleaned true);
              Eio.Promise.resolve worker_started_u ();
              Eio.Fiber.await_cancel ()))) with
        | () -> fail "a cancelled invocation returned normally"
        | exception Stop_pool_submission -> ()) in
      let owner_sw = Eio.Promise.await owner_switch in
      Eio.Promise.await worker_started;
      Eio.Switch.fail owner_sw Stop_pool_submission;
      let first = Eio.Fiber.first
          (fun () -> Eio.Promise.await cleanup_started; `Worker_cleanup)
          (fun () -> Eio.Promise.await_exn owner; `Owner_returned) in
      check bool "actual worker cleanup starts before the owner can return" true
        (first = `Worker_cleanup);
      check bool "the cancelled owner still owns the held cleanup" false
        (Eio.Promise.is_resolved owner);
      Eio.Promise.resolve sibling_release_u ();
      check string "another admitted submission survives cancellation" "independent sibling"
        (Eio.Promise.await_exn sibling);
      Eio.Promise.resolve cleanup_release_u ();
      Eio.Promise.await_exn owner;
      check bool "worker cleanup finished before cancellation settled" true (Atomic.get cleaned);
      check int "user work was invoked once" 1 (Atomic.get entered);
      check int "the same pool accepts later work" 42 (D.submit_cpu ~name:__FUNCTION__ pool (fun () -> 42))))

let test_cancellation_before_admission_does_not_run_user_work shape () =
  with_submission_pool (fun ~sw pool ->
    let occupied,occupied_u = Eio.Promise.create () in
    let release,release_u = Eio.Promise.create () in
    let attempted,attempted_u = Eio.Promise.create () in
    let owner_switch,owner_switch_u = Eio.Promise.create () in
    let entered = Atomic.make 0 in
    Fun.protect ~finally:(fun () -> ignore (Eio.Promise.try_resolve release_u ())) (fun () ->
      let occupant = D.submit_cpu_async ~name:__FUNCTION__ ~sw pool (fun () ->
        Eio.Promise.resolve occupied_u ();
        Eio.Promise.await release) in
      Eio.Promise.await occupied;
      let owner = Eio.Fiber.fork_promise ~sw (fun () ->
        match Eio.Switch.run (fun owner_sw ->
          Eio.Promise.resolve owner_switch_u owner_sw;
          Eio.Promise.resolve attempted_u ();
          run_unit_submission shape ~sw:owner_sw pool (fun () ->
            ignore (Atomic.fetch_and_add entered 1))) with
        | () -> fail "a submission waiting behind occupied capacity returned normally"
        | exception Stop_pool_submission -> ()) in
      let owner_sw = Eio.Promise.await owner_switch in
      Eio.Promise.await attempted;
      Eio.Switch.fail owner_sw Stop_pool_submission;
      Eio.Promise.await_exn owner;
      Eio.Promise.resolve release_u ();
      Eio.Promise.await_exn occupant;
      ignore (D.submit_cpu ~name:__FUNCTION__ pool (fun () -> ()));
      check int "cancelled work never enters after pool capacity becomes free" 0 (Atomic.get entered)))

let test_worker_failure_preserves_exception_and_does_not_replay shape () =
  with_submission_pool (fun ~sw pool ->
    let applied = Atomic.make 0 in
    let original = Failure "user work already applied its effect" in
    (match run_unit_submission shape ~sw pool (fun () ->
      ignore (Atomic.fetch_and_add applied 1);
      raise original) with
     | () -> fail "worker failure disappeared"
     | exception actual -> check bool "the original worker exception is preserved" true (actual == original));
    check int "failed effectful work is never retried inline" 1 (Atomic.get applied);
    check string "failure does not close the pool" "next invocation"
      (D.submit_io ~name:__FUNCTION__ pool (fun () -> "next invocation")))

let test_async_observer_does_not_cancel_owned_submission submit () =
  with_submission_pool (fun ~sw pool ->
    let started,started_u = Eio.Promise.create () in
    let release,release_u = Eio.Promise.create () in
    let product = ref "original worker product" in
    Fun.protect ~finally:(fun () -> ignore (Eio.Promise.try_resolve release_u ())) (fun () ->
      let job = submit ~sw pool (fun () ->
        Eio.Promise.resolve started_u ();
        Eio.Promise.await release;
        product) in
      Eio.Fiber.first
        (fun () -> Eio.Promise.await started)
        (fun () -> ignore (Eio.Promise.await_exn job));
      check bool "cancelling a result observer does not settle the owned submission" false
        (Eio.Promise.is_resolved job);
      Eio.Promise.resolve release_u ();
      check bool "the original submission still returns its actual product" true
        (Eio.Promise.await_exn job == product)))

let test_invalid_executor_weight_never_invokes_user_work () =
  with_submission_pool (fun ~sw:_ _pool ->
    let applied = ref 0 in
    let operation () = incr applied in
    (match Executor_pool_ref.submit_or_inline ~name:__FUNCTION__ ~weight:Float.nan operation with
     | () -> fail "invalid executor admission ran user work inline"
     | exception Invalid_argument _ -> ());
    check int "invalid admission did not run the effect" 0 !applied;
    (match Executor_pool_ref.submit_strict ~name:__FUNCTION__ ~weight:Float.nan operation with
     | Error (Executor_pool_ref.Submission_failed (Invalid_argument _,_)) -> ()
     | Error (Pool_unavailable | Caller_not_in_eio | Work_failed _ | Submission_failed _)
     | Ok () -> fail "strict executor lost the infrastructure failure boundary");
    check int "strict invalid admission also left user work untouched" 0 !applied)

(* ── Suite ──────────────────────────────────────────────── *)

let () =
  Alcotest.run "Domain_pool" [
    "submission ownership", [
      test_case "async IO observer does not own worker cancellation" `Quick
        (test_async_observer_does_not_cancel_owned_submission (D.submit_io_async ~name:__FUNCTION__));
      test_case "async CPU observer does not own worker cancellation" `Quick
        (test_async_observer_does_not_cancel_owned_submission (D.submit_cpu_async ~name:__FUNCTION__));
      test_case "invalid executor admission never runs user work" `Quick
        test_invalid_executor_weight_never_invokes_user_work;
    ];
    "owned cancellation", List.concat_map (fun shape ->
      let name = submission_name shape in
      [test_case (name ^ " joins worker cleanup and preserves siblings") `Quick
         (test_cancelled_submission_joins_worker_cleanup shape);
       test_case (name ^ " does not enter cancelled queued work") `Quick
         (test_cancellation_before_admission_does_not_run_user_work shape);
       test_case (name ^ " preserves failed effects without replay") `Quick
         (test_worker_failure_preserves_exception_and_does_not_replay shape)]) submission_shapes;
    "recommended", [
      test_case "positive floor" `Quick test_recommended_domain_count_floor;
      test_case "reserves scheduler headroom" `Quick
        test_recommended_domain_count_reserves_scheduler_headroom;
    ];
    "create", [
      test_case "default count" `Quick test_create_default;
      test_case "explicit count" `Quick test_create_explicit;
      test_case "zero rejected" `Quick test_create_zero_rejected;
      test_case "negative rejected" `Quick test_create_negative_rejected;
    ];
    "submit_blocking", [
      test_case "cpu returns value" `Quick test_submit_cpu_returns_value;
      test_case "io returns value" `Quick test_submit_io_returns_value;
      test_case "cpu propagates exn" `Quick
        test_submit_cpu_propagates_exception;
    ];
    "submit_async", [
      test_case "cpu promise resolves" `Quick test_submit_cpu_async_resolves;
      test_case "io promise resolves" `Quick test_submit_io_async_resolves;
      test_case "async propagates exn" `Quick
        test_submit_async_propagates_exception;
    ];
    "multi_domain", [
      test_case "jobs run off main domain" `Quick
        test_jobs_run_on_worker_domains;
    ];
    "minor_heap", [
      test_case "pool work runs on the tuned minor heap" `Quick
        test_pool_work_runs_on_the_tuned_minor_heap;
    ];
    "escape_hatch", [
      test_case "executor_pool accessor" `Quick test_executor_pool_accessor;
    ];
    "ref", [
      test_case "inline when absent" `Quick test_ref_runs_inline_when_absent;
      test_case "submits to shared pool" `Quick test_ref_submits_to_shared_pool;
      test_case "Keeper model-input projection uses shared pool" `Quick
        test_keeper_model_input_projection_uses_shared_pool;
      test_case "inline from raw domain with pool installed" `Quick
        test_ref_inline_from_raw_domain_with_pool;
      test_case "a job that submits again runs the inner work on its worker" `Quick
        test_a_job_that_submits_again_runs_the_inner_work_on_its_worker;
      test_case "a job still running after another ends is pool work" `Quick
        test_a_job_still_running_after_another_ends_is_pool_work;
    ];
  ]
