open Alcotest

module KF = Masc.Keeper_fs

exception Synthetic_owner_failure

(* This is a test-runner watchdog, not a production scheduling policy. It
   localizes a coordination liveness regression instead of consuming the
   quick-suite-wide 35 minute watchdog. *)
let coordination_watchdog_seconds = 5.0

type owner_fault =
  | Ordinary_failure
  | Cancellation

type owner_outcome =
  | Owner_error of KF.durable_write_error
  | Owner_cancelled

type blocking_hook =
  { trigger_parent : string
  ; entered : unit Eio.Promise.t
  ; resolve_entered : unit Eio.Promise.u
  ; armed : bool Atomic.t
  ; mutex : Stdlib.Mutex.t
  ; condition : Stdlib.Condition.t
  ; mutable released : bool
  }

let blocking_hook trigger_parent =
  let entered, resolve_entered = Eio.Promise.create () in
  { trigger_parent
  ; entered
  ; resolve_entered
  ; armed = Atomic.make true
  ; mutex = Stdlib.Mutex.create ()
  ; condition = Stdlib.Condition.create ()
  ; released = false
  }
;;

let release_blocking_hook hook =
  Stdlib.Mutex.protect hook.mutex (fun () ->
    if not hook.released
    then (
      hook.released <- true;
      Stdlib.Condition.broadcast hook.condition))
;;

let with_blocking_hook_release hook f =
  Fun.protect ~finally:(fun () -> release_blocking_hook hook) f
;;

let await_blocking_hook_release hook =
  Stdlib.Mutex.lock hook.mutex;
  Fun.protect
    ~finally:(fun () -> Stdlib.Mutex.unlock hook.mutex)
    (fun () ->
       while not hook.released do
         Stdlib.Condition.wait hook.condition hook.mutex
       done)
;;

let block_once hook after_release parent =
  if
    String.equal parent hook.trigger_parent
    && Atomic.compare_and_set hook.armed true false
  then (
    Eio.Promise.resolve hook.resolve_entered ();
    await_blocking_hook_release hook;
    after_release ())
;;

let temp_dir () =
  let dir = Filename.temp_file "test_keeper_fs_directory_durability_" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir
;;

let cleanup_dir dir =
  let rec remove path =
    if Sys.file_exists path
    then
      if Sys.is_directory path
      then (
        Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);
        Unix.rmdir path)
      else Unix.unlink path
  in
  try remove dir with
  | Sys_error _ | Unix.Unix_error _ -> ()
;;

let require_ok label = function
  | Ok () -> ()
  | Error detail -> failf "%s: %s" label detail
;;

let require_durable_ok label = function
  | Ok () -> ()
  | Error detail -> failf "%s: %s" label (KF.durable_write_error_to_string detail)
;;

let with_eio_guard f =
  Eio_guard.enable ();
  Fun.protect ~finally:Eio_guard.disable f
;;

let test_non_directory_ancestor_does_not_poison_preparation () =
  Eio_main.run
  @@ fun _env ->
  with_eio_guard
  @@ fun () ->
  KF.clear_dir_cache ();
  let base = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base)
    (fun () ->
       let occupied = Filename.concat base "occupied" in
       require_ok "seed non-directory ancestor" (KF.save_atomic occupied "not a directory");
       let blocked_path = Filename.concat occupied "request.json" in
       (match KF.save_json_durable_atomic blocked_path (`Assoc []) with
        | Error
            { renamed = false
            ; stage = KF.Directory_prepare
            ; failure = KF.Directory_chain_failed (KF.Non_directory_ancestor { path })
            } ->
          check string "typed failure retains occupied path" occupied path
        | Error error ->
          failf
            "unexpected durable write error: %s"
            (KF.durable_write_error_to_string error)
        | Ok () -> fail "non-directory ancestor unexpectedly accepted");
       let sibling_path = Filename.concat base "sibling/request.json" in
       match KF.save_json_durable_atomic sibling_path (`Assoc []) with
       | Ok () -> ()
       | Error error ->
         failf
           "directory prepare failure poisoned the next write: %s"
           (KF.durable_write_error_to_string error))
;;

let test_retry_reanchors_partial_directory () =
  Eio_main.run
  @@ fun _env ->
  with_eio_guard
  @@ fun () ->
  KF.clear_dir_cache ();
  let base = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base)
    (fun () ->
       let partial = Filename.concat base "partial" in
       let path = Filename.concat partial "leaf/request.json" in
       let injected = ref false in
       let first =
         KF.For_testing.save_json_durable_atomic
           ~before_stage:(fun _ -> ())
           ~before_directory_fsync:(fun parent ->
             if (not !injected) && String.equal parent base
             then (
               injected := true;
               failwith "injected directory fsync failure"))
           path
           (`Assoc [])
       in
       (match first with
        | Error { renamed = false; stage = KF.Directory_prepare; _ } -> ()
        | Error error ->
          failf
            "unexpected durable write error: %s"
            (KF.durable_write_error_to_string error)
        | Ok () -> fail "injected directory fsync failure unexpectedly succeeded");
       check bool "directory fsync fault was injected" true !injected;
       check bool "failed component remains visible" true (Sys.is_directory partial);
       let partial_reanchored = ref false in
       (match
          KF.For_testing.save_json_durable_atomic
            ~before_stage:(fun _ -> ())
            ~before_directory_fsync:(fun parent ->
              if String.equal parent base then partial_reanchored := true)
            path
            (`Assoc [])
        with
        | Ok () -> ()
        | Error error ->
          failf
            "retry after directory fsync failure failed: %s"
            (KF.durable_write_error_to_string error));
       check bool "retry re-anchors the visible component" true !partial_reanchored)
;;

let run_owner_fault_wakes_waiter fault () =
  Eio_main.run
  @@ fun _env ->
  with_eio_guard
  @@ fun () ->
  KF.clear_dir_cache ();
  let base = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base)
    (fun () ->
       let contended = Filename.concat base "contended" in
       let path = Filename.concat contended "request.json" in
       let hook = blocking_hook base in
       let owner_result, resolve_owner_result = Eio.Promise.create () in
       let waiter_started, resolve_waiter_started = Eio.Promise.create () in
       let waiter_result, resolve_waiter_result = Eio.Promise.create () in
       let waiter_prepared = Atomic.make false in
       Eio.Switch.run
       @@ fun sw ->
       Eio.Fiber.fork ~sw (fun () ->
         let outcome =
           try
             match
               KF.For_testing.save_json_durable_atomic
                 ~before_stage:(fun _ -> ())
                 ~before_directory_fsync:
                   (block_once hook (fun () ->
                      match fault with
                      | Ordinary_failure -> raise Synthetic_owner_failure
                      | Cancellation ->
                        raise (Eio.Cancel.Cancelled (Failure "synthetic owner cancel"))))
                 path
                 (`Assoc [])
             with
             | Ok () -> fail "faulted owner unexpectedly succeeded"
             | Error error -> Owner_error error
           with
           | Eio.Cancel.Cancelled _ -> Owner_cancelled
         in
         Eio.Promise.resolve resolve_owner_result outcome);
       Eio.Promise.await hook.entered;
       Eio.Fiber.fork ~sw (fun () ->
         Eio.Promise.resolve resolve_waiter_started ();
         let result =
           KF.For_testing.save_json_durable_atomic
             ~before_stage:(function
               | KF.Directory_prepare -> Atomic.set waiter_prepared true
               | _ -> ())
             path
             (`Assoc [])
         in
         Eio.Promise.resolve resolve_waiter_result result);
       Fun.protect
         ~finally:(fun () -> release_blocking_hook hook)
         (fun () ->
            Eio.Promise.await waiter_started;
            release_blocking_hook hook;
            (match fault, Eio.Promise.await owner_result with
             | Ordinary_failure, Owner_error { stage = KF.Directory_prepare; _ } -> ()
             | Cancellation, Owner_cancelled -> ()
             | Ordinary_failure, Owner_error error ->
               failf
                 "owner failed at unexpected stage: %s"
                 (KF.durable_write_error_to_string error)
             | Cancellation, Owner_error error ->
               failf
                 "owner cancellation was converted to an error: %s"
                 (KF.durable_write_error_to_string error)
             | Ordinary_failure, Owner_cancelled ->
               fail "ordinary owner failure propagated as cancellation");
            require_durable_ok "waiter takeover" (Eio.Promise.await waiter_result);
            check bool "woken waiter owns retry" true (Atomic.get waiter_prepared)))
;;

let test_owner_failure_wakes_waiter = run_owner_fault_wakes_waiter Ordinary_failure
let test_owner_cancellation_wakes_waiter = run_owner_fault_wakes_waiter Cancellation

let test_owner_context_cancellation_wakes_waiter () =
  Eio_main.run
  @@ fun _env ->
  with_eio_guard
  @@ fun () ->
  KF.clear_dir_cache ();
  let base = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base)
    (fun () ->
       let path = Filename.concat base "context-cancelled/request.json" in
       let owner_context, resolve_owner_context = Eio.Promise.create () in
       let owner_entered, resolve_owner_entered = Eio.Promise.create () in
       let owner_result, resolve_owner_result = Eio.Promise.create () in
       let waiter_started, resolve_waiter_started = Eio.Promise.create () in
       let waiter_result, resolve_waiter_result = Eio.Promise.create () in
       let waiter_prepared = Atomic.make false in
       Eio.Switch.run
       @@ fun sw ->
       Eio.Fiber.fork ~sw (fun () ->
         let outcome =
           try
             Eio.Cancel.sub (fun context ->
               Eio.Promise.resolve resolve_owner_context context;
               match
                 KF.For_testing.save_json_durable_atomic
                   ~before_stage:(function
                     | KF.Directory_prepare ->
                       Eio.Promise.resolve resolve_owner_entered ();
                       Eio.Fiber.await_cancel ()
                     | _ -> ())
                   path
                   (`Assoc [])
               with
               | Ok () -> fail "context-cancelled owner unexpectedly succeeded"
               | Error error -> Owner_error error)
           with
           | Eio.Cancel.Cancelled _ -> Owner_cancelled
         in
         Eio.Promise.resolve resolve_owner_result outcome);
       let context = Eio.Promise.await owner_context in
       Eio.Promise.await owner_entered;
       Eio.Fiber.fork ~sw (fun () ->
         Eio.Promise.resolve resolve_waiter_started ();
         let result =
           KF.For_testing.save_json_durable_atomic
             ~before_stage:(function
               | KF.Directory_prepare -> Atomic.set waiter_prepared true
               | _ -> ())
             path
             (`Assoc [])
         in
         Eio.Promise.resolve resolve_waiter_result result);
       Eio.Promise.await waiter_started;
       Eio.Cancel.cancel context Synthetic_owner_failure;
       (match Eio.Promise.await owner_result with
        | Owner_cancelled -> ()
        | Owner_error error ->
          failf
            "owner context cancellation was converted to an error: %s"
            (KF.durable_write_error_to_string error));
       require_durable_ok "context-cancelled waiter takeover"
         (Eio.Promise.await waiter_result);
       check bool "context-cancelled waiter owns retry" true
         (Atomic.get waiter_prepared))
;;

let test_independent_suffix_progresses_after_common_prefix () =
  Eio_main.run
  @@ fun env ->
  Eio.Time.with_timeout_exn
    (Eio.Stdenv.clock env)
    coordination_watchdog_seconds
  @@ fun () ->
  with_eio_guard
  @@ fun () ->
  KF.clear_dir_cache ();
  let base = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base)
    (fun () ->
       let common = Filename.concat base "common" in
       let owner_path = Filename.concat common "left/deep/request.json" in
       let sibling_path = Filename.concat common "right/request.json" in
       let hook = blocking_hook common in
       let owner_result, resolve_owner_result = Eio.Promise.create () in
       let sibling_result, resolve_sibling_result = Eio.Promise.create () in
       let sibling_claimed_before_release = Atomic.make false in
       Eio.Switch.run
       @@ fun sw ->
       with_blocking_hook_release hook
       @@ fun () ->
       Eio.Fiber.fork ~sw (fun () ->
         let result =
           KF.For_testing.save_json_durable_atomic
             ~before_stage:(fun _ -> ())
             ~before_directory_fsync:(block_once hook (fun () -> ()))
             owner_path
             (`Assoc [])
         in
         Eio.Promise.resolve resolve_owner_result result);
       Eio.Promise.await hook.entered;
       Eio.Fiber.fork ~sw (fun () ->
         let result =
           KF.For_testing.save_json_durable_atomic
             ~before_stage:(function
               | KF.Directory_prepare ->
                 Atomic.set sibling_claimed_before_release true;
                 release_blocking_hook hook
               | _ -> ())
             sibling_path
             (`Assoc [])
         in
         Eio.Promise.resolve resolve_sibling_result result);
       require_durable_ok "independent sibling" (Eio.Promise.await sibling_result);
       require_durable_ok "blocked owner" (Eio.Promise.await owner_result);
       check bool "sibling claims its suffix before owner release" true
         (Atomic.get sibling_claimed_before_release))
;;

let test_invalidate_reaps_resolved_ticket () =
  Eio_main.run
  @@ fun env ->
  Eio.Time.with_timeout_exn
    (Eio.Stdenv.clock env)
    coordination_watchdog_seconds
  @@ fun () ->
  with_eio_guard
  @@ fun () ->
  KF.clear_dir_cache ();
  let base = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base)
    (fun () ->
       let common = Filename.concat base "common" in
       let owner_path = Filename.concat common "deep/leaf/request.json" in
       let reclaimer_path = Filename.concat common "reclaimed.json" in
       let hook = blocking_hook common in
       let owner_result, resolve_owner_result = Eio.Promise.create () in
       let reclaimer_result, resolve_reclaimer_result = Eio.Promise.create () in
       let reclaimed_before_release = Atomic.make false in
       Eio.Switch.run
       @@ fun sw ->
       with_blocking_hook_release hook
       @@ fun () ->
       Eio.Fiber.fork ~sw (fun () ->
         let result =
           KF.For_testing.save_json_durable_atomic
             ~before_stage:(fun _ -> ())
             ~before_directory_fsync:(block_once hook (fun () -> ()))
             owner_path
             (`Assoc [])
         in
         Eio.Promise.resolve resolve_owner_result result);
       Eio.Promise.await hook.entered;
       KF.invalidate_dir common;
       Eio.Fiber.fork ~sw (fun () ->
         let result =
           KF.For_testing.save_json_durable_atomic
             ~before_stage:(function
               | KF.Directory_prepare ->
                 Atomic.set reclaimed_before_release true;
                 release_blocking_hook hook
               | _ -> ())
             reclaimer_path
             (`Assoc [])
         in
         Eio.Promise.resolve resolve_reclaimer_result result);
       require_durable_ok "invalidated prefix reclaimer"
         (Eio.Promise.await reclaimer_result);
       require_durable_ok "original owner" (Eio.Promise.await owner_result);
       check bool "resolved ticket is reaped before owner release" true
         (Atomic.get reclaimed_before_release))
;;

let () =
  run
    "Keeper_fs directory durability"
    [ ( "directory preparation"
      , [ test_case
            "non-directory ancestor does not poison preparation"
            `Quick
            test_non_directory_ancestor_does_not_poison_preparation
        ; test_case
            "retry re-anchors partial directory"
            `Quick
            test_retry_reanchors_partial_directory
        ] )
    ; ( "coordination"
      , [ test_case
            "owner failure wakes waiter takeover"
            `Quick
            test_owner_failure_wakes_waiter
        ; test_case
            "owner cancellation wakes waiter takeover"
            `Quick
            test_owner_cancellation_wakes_waiter
        ; test_case
            "owner context cancellation wakes waiter takeover"
            `Quick
            test_owner_context_cancellation_wakes_waiter
        ; test_case
            "independent suffix progresses after common prefix"
            `Quick
            test_independent_suffix_progresses_after_common_prefix
        ; test_case
            "invalidate reaps resolved ticket"
            `Quick
            test_invalidate_reaps_resolved_ticket
        ] )
    ]
;;
