open Alcotest

(** Regression for the 2026-06-19 keeper stall.

    The dashboard metrics cache compute was offloaded via
    [Eio_guard.run_in_systhread] — a bare OS thread with no Eio effect handler.
    The compute reached [Keeper_fs.ensure_dir], which takes the process-shared
    [dir_mu] through [Eio.Mutex.use_rw ~protect:true].  [Cancel.protect]
    performs [Get_context] as its first action; with no handler on the systhread
    that raises [Effect.Unhandled], which [use_rw] converts into a poison of
    [dir_mu].  Every file write in the process then failed with
    [Eio.Mutex.Poisoned], so no keeper could persist and the fleet stalled.

    The fix routes such compute through [Executor_pool_ref.submit_or_inline],
    which runs the closure as a real Eio fiber (under [Eio.Switch.run], on a
    worker domain or inline), so [use_rw] keeps its [Get_context] handler and
    the mutex is never poisoned.  These tests pin both directions. *)

(* True iff taking [mu] raises [Eio.Mutex.Poisoned] (i.e. the mutex is dead). *)
let poisons mu =
  try
    Eio.Mutex.use_rw ~protect:true mu (fun () -> ());
    false
  with
  | Eio.Mutex.Poisoned _ -> true

(* The bug: a bare systhread has no Eio handler, so [use_rw] inside it raises
   [Effect.Unhandled(Get_context)] and poisons the mutex. This is exactly why
   the dashboard cache compute must NOT use [Eio_guard.run_in_systhread]. *)
let test_systhread_offload_poisons_mutex () =
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun _sw ->
      Eio_guard.enable ();
      Fun.protect ~finally:Eio_guard.disable (fun () ->
        let mu = Eio.Mutex.create () in
        let raised =
          try
            Eio_guard.run_in_systhread ~label:"test-eio-mutex-poison" (fun () ->
              Eio.Mutex.use_rw ~protect:true mu (fun () -> ()));
            false
          with
          | _ -> true
        in
        check bool "use_rw inside a bare systhread raises" true raised;
        check bool "and leaves the mutex poisoned" true (poisons mu))))

(* The diagnostic (defense-in-depth, Eio_guard.run_in_systhread): the bug still
   poisons the mutex, but the exception surfaced out of [run_in_systhread] is now
   an actionable [Failure] naming the misuse and the Executor_pool alternative,
   instead of a bare [Effect.Unhandled]. This pins the conversion: on the
   pre-hardening code the body raised [Effect.Unhandled] (caught here by [_ ->
   false] -> test fails); after the hardening it is a [Failure] (-> test passes). *)
let test_systhread_offload_raises_actionable_failure () =
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun _sw ->
      Eio_guard.enable ();
      Fun.protect ~finally:Eio_guard.disable (fun () ->
        let mu = Eio.Mutex.create () in
        let is_failure =
          try
            Eio_guard.run_in_systhread ~label:"test-eio-mutex-poison-diagnostic" (fun () ->
              Eio.Mutex.use_rw ~protect:true mu (fun () -> ()));
            false
          with
          | Failure _ -> true
          | _ -> false
        in
        check bool "run_in_systhread surfaces a Failure, not a bare Effect.Unhandled"
          true is_failure)))

(* The fix: [submit_or_inline] runs the closure with a live Eio context, so the
   same [use_rw] resolves and the mutex stays usable afterwards. *)
let test_submit_or_inline_preserves_mutex () =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      Eio_guard.enable ();
      Fun.protect ~finally:Eio_guard.disable (fun () ->
        let dm = Eio.Stdenv.domain_mgr env in
        let pool = Domain_pool.create ~sw ~domain_count:1 dm in
        Executor_pool_ref.For_testing.with_pool
          (Domain_pool.executor_pool pool)
        @@ fun () ->
        let mu = Eio.Mutex.create () in
        let v =
          Executor_pool_ref.submit_or_inline (fun () ->
            Eio.Mutex.use_rw ~protect:true mu (fun () -> 7))
        in
        check int "use_rw inside offloaded closure returns its value" 7 v;
        check bool "shared mutex is not poisoned after offload" false
          (poisons mu))))

let context_label = function
  | Eio_guard.Eio_fiber -> "eio_fiber"
  | Eio_guard.Non_eio -> "non_eio"

let test_ready_raw_domain_uses_non_eio_path () =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      Eio_guard.enable ();
      Fun.protect ~finally:Eio_guard.disable (fun () ->
        let pool =
          Domain_pool.create ~sw ~domain_count:1 (Eio.Stdenv.domain_mgr env)
        in
        Executor_pool_ref.For_testing.with_pool
          (Domain_pool.executor_pool pool)
        @@ fun () ->
        check string "main caller has Eio handler" "eio_fiber"
          (context_label (Eio_guard.execution_context ()));
        let raw_mutex = Eio.Mutex.create () in
        let durable_dir = Filename.temp_file "masc-raw-domain-dir-" "" in
        Unix.unlink durable_dir;
        Eio.Switch.on_release sw (fun () ->
          if Sys.file_exists durable_dir then Unix.rmdir durable_dir);
        let caller_context, submitted_context, systhread_value, cleanup_ran,
            mutex_rejected, directory_result =
          Domain.spawn (fun () ->
            let cleanup_ran = ref false in
            let protected_value =
              Eio_guard.protect
                ~finally:(fun () -> cleanup_ran := true)
                (fun () -> 17)
            in
            let mutex_rejected =
              match Eio_guard.with_mutex raw_mutex (fun () -> ()) with
              | () -> false
              | exception
                  Eio_guard.Non_eio_mutex_context Eio_guard.Read_write -> true
              | exception
                  Eio_guard.Non_eio_mutex_context Eio_guard.Read_only -> false
            in
            let directory_result =
              Masc.Keeper_fs_durable_directory.ensure
                ~before_prepare:(fun () -> ())
                ~before_directory_fsync:(fun _ -> ())
                durable_dir
            in
            ( Eio_guard.execution_context ()
            , Executor_pool_ref.submit_or_inline Eio_guard.execution_context
            , Eio_guard.run_in_systhread ~label:"test-protected-value" (fun () -> protected_value)
            , !cleanup_ran
            , mutex_rejected
            , directory_result ))
          |> Domain.join
        in
        check string "raw Domain is not inferred from global ready" "non_eio"
          (context_label caller_context);
        check string "raw Domain does not enter the Eio executor" "non_eio"
          (context_label submitted_context);
        check int "raw Domain executes blocking body directly" 17 systhread_value;
        check bool "raw Domain cleanup uses Fun.protect" true cleanup_ran;
        check bool "ready raw Domain cannot enter an Eio mutex" true
          mutex_rejected;
        (match directory_result with
         | Ok _ -> check bool "raw Domain prepares durable directory" true
                     (Sys.is_directory durable_dir)
         | Error (Masc.Keeper_fs_durable_directory.Directory_chain_failed _) ->
           fail "raw Domain durable-directory chain failed"
         | Error (Masc.Keeper_fs_durable_directory.Operation_failed (exn, _)) ->
           fail ("raw Domain durable-directory operation failed: "
                 ^ Printexc.to_string exn)))))

exception With_pool_probe

let same_pool_option left right =
  match left, right with
  | None, None -> true
  | Some left, Some right -> left == right
  | None, Some _ | Some _, None -> false

let test_with_pool_restores_exact_previous_pool_after_exception () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let make_pool () =
    Domain_pool.create
      ~sw
      ~domain_count:1
      (Eio.Stdenv.domain_mgr env)
    |> Domain_pool.executor_pool
  in
  let outer = make_pool () in
  let inner = make_pool () in
  let initial = Executor_pool_ref.get () in
  Executor_pool_ref.For_testing.with_pool outer (fun () ->
    let raised =
      try
        Executor_pool_ref.For_testing.with_pool inner (fun () ->
          check bool
            "inner pool installed"
            true
            (same_pool_option (Some inner) (Executor_pool_ref.get ()));
          raise With_pool_probe)
      with
      | With_pool_probe -> true
    in
    check bool "probe propagated" true raised;
    check bool
      "outer pool restored"
      true
      (same_pool_option (Some outer) (Executor_pool_ref.get ())));
  check bool
    "initial option restored"
    true
    (same_pool_option initial (Executor_pool_ref.get ()))
;;

let test_submit_strict_absent_pool_does_not_run () =
  Executor_pool_ref.For_testing.with_pool_option None
  @@ fun () ->
  let calls = ref 0 in
  match
    Executor_pool_ref.submit_strict (fun () ->
      incr calls;
      7)
  with
  | Error Executor_pool_ref.Pool_unavailable ->
    check int "absent pool does not execute the closure" 0 !calls
  | Error error ->
    fail
      ("unexpected strict submission error: "
       ^ Executor_pool_ref.strict_submit_error_to_string error)
  | Ok _ -> fail "strict submission ran without an installed pool"
;;

exception Strict_worker_failure

let test_submit_strict_worker_failure_is_not_replayed_inline () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  Eio_guard.enable ();
  Fun.protect
    ~finally:Eio_guard.disable
    (fun () ->
       let pool =
         Domain_pool.create
           ~sw
           ~domain_count:1
           (Eio.Stdenv.domain_mgr env)
       in
       Executor_pool_ref.For_testing.with_pool
         (Domain_pool.executor_pool pool)
       @@ fun () ->
       let caller_domain = Domain.self () in
       let calls = Atomic.make 0 in
       let ran_off_caller = Atomic.make false in
       let result =
         Executor_pool_ref.submit_strict (fun () ->
           ignore (Atomic.fetch_and_add calls 1);
           Atomic.set ran_off_caller (Domain.self () <> caller_domain);
           raise Strict_worker_failure)
       in
       (match result with
        | Error (Executor_pool_ref.Work_failed (Strict_worker_failure, _)) -> ()
        | Error error ->
          fail
            ("unexpected strict submission error: "
             ^ Executor_pool_ref.strict_submit_error_to_string error)
        | Ok _ -> fail "worker failure was reported as success");
       check int "failed worker closure executes once" 1 (Atomic.get calls);
       check bool "failed worker closure never replays inline" true
         (Atomic.get ran_off_caller))
;;

let test_startup_installs_pool_before_strict_read () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  Eio_guard.enable ();
  Fun.protect
    ~finally:Eio_guard.disable
    (fun () ->
       let pool =
         Domain_pool.create
           ~sw
           ~domain_count:1
           (Eio.Stdenv.domain_mgr env)
       in
       let previous_domain_pool = Domain_pool_ref.get () in
       Executor_pool_ref.For_testing.with_pool_option None
       @@ fun () ->
       Fun.protect
         ~finally:(fun () ->
           match previous_domain_pool with
           | None -> Domain_pool_ref.clear_for_tests ()
           | Some previous -> Domain_pool_ref.set previous)
         (fun () ->
            let caller_domain = Domain.self () in
            Server_runtime_bootstrap.For_testing.install_domain_pool_references pool;
            match
              Executor_pool_ref.submit_strict (fun () ->
                Domain.self () <> caller_domain)
            with
            | Ok ran_off_caller ->
              check bool "startup-installed pool owns the first strict read" true
                ran_off_caller
            | Error error ->
              fail
                ("startup did not install the strict executor pool: "
                 ^ Executor_pool_ref.strict_submit_error_to_string error)))
;;

let () =
  Alcotest.run "Executor_pool_ref Eio mutex safety"
    [ ( "offload"
      , [ test_case "systhread offload poisons the mutex (bug)" `Quick
            test_systhread_offload_poisons_mutex
        ; test_case "systhread offload raises an actionable Failure (diagnostic)" `Quick
            test_systhread_offload_raises_actionable_failure
        ; test_case "submit_or_inline preserves the mutex (fix)" `Quick
            test_submit_or_inline_preserves_mutex
        ; test_case "ready raw Domain uses the non-Eio path" `Quick
            test_ready_raw_domain_uses_non_eio_path
        ; test_case "with_pool restores after exception" `Quick
            test_with_pool_restores_exact_previous_pool_after_exception
        ; test_case "strict absent pool does not run" `Quick
            test_submit_strict_absent_pool_does_not_run
        ; test_case "strict worker failure is not replayed" `Quick
            test_submit_strict_worker_failure_is_not_replayed_inline
        ; test_case "startup installs pool before strict read" `Quick
            test_startup_installs_pool_before_strict_read
        ] )
    ]
