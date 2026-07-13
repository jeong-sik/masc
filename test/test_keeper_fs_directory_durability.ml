open Alcotest

module KF = Masc.Keeper_fs
module KDD = Masc.Keeper_fs_durable_directory

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
    match Unix.lstat path with
    | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
    | { Unix.st_kind = Unix.S_DIR; _ } ->
        Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);
        Unix.rmdir path
    | _ -> Unix.unlink path
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

let require_directory_lease label = function
  | Ok _ -> ()
  | Error _ -> failf "%s: directory lease preparation failed" label
;;

let with_eio_guard f =
  Eio_guard.enable ();
  Fun.protect ~finally:Eio_guard.disable f
;;

let with_env name value f =
  let previous = Sys.getenv_opt name in
  Unix.putenv name value;
  Fun.protect
    ~finally:(fun () -> Unix.putenv name (Option.value ~default:"" previous))
    f
;;

let with_strict_malformed_disk_pressure_cooldown f =
  with_env "MASC_PARSE_WARN" "true" (fun () ->
    with_env "MASC_KEEPER_DISK_PRESSURE_COOLDOWN_SEC" "not-a-float" f)
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

let test_symlink_ancestor_is_rejected () =
  Eio_main.run
  @@ fun _env ->
  with_eio_guard
  @@ fun () ->
  KF.clear_dir_cache ();
  let base = temp_dir () in
  let outside = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base; cleanup_dir outside)
    (fun () ->
       let linked = Filename.concat base "linked" in
       Unix.symlink outside linked;
       let path = Filename.concat linked "request.json" in
       let weak_json = `Assoc [ "mode", `String "legacy-follow" ] in
       require_durable_ok
         "seed weak cached symlink path"
         (KF.save_json_durable_atomic path weak_json);
       (match
          KF.save_json_durable_atomic
            ~ownership_root:base
            path
            (`Assoc [ "mode", `String "strict" ])
        with
        | Error
            { renamed = false
            ; stage = KF.Directory_prepare
            ; failure = KF.Directory_chain_failed (KF.Non_directory_ancestor { path })
            } ->
          check string "typed failure retains symlink path" linked path
        | Error error ->
          failf
            "unexpected durable write error: %s"
            (KF.durable_write_error_to_string error)
        | Ok () -> fail "symlink ancestor unexpectedly accepted");
       check string "strict write did not overwrite outside target"
         (Yojson.Safe.pretty_to_string weak_json)
         (Fs_compat.load_file (Filename.concat outside "request.json")))
;;

let test_cached_owned_chain_rejects_symlink_retarget () =
  Eio_main.run
  @@ fun _env ->
  with_eio_guard
  @@ fun () ->
  KF.clear_dir_cache ();
  let base = temp_dir () in
  let outside = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base; cleanup_dir outside)
    (fun () ->
       let linked = Filename.concat base "linked" in
       let retired = Filename.concat base "retired" in
       Unix.mkdir linked 0o755;
       let path = Filename.concat linked "request.json" in
       require_durable_ok
         "seed strict cached directory"
         (KF.save_json_durable_atomic
            ~ownership_root:base
            path
            (`Assoc [ "generation", `Int 1 ]));
       Unix.rename linked retired;
       Unix.symlink outside linked;
       (match
          KF.save_json_durable_atomic
            ~ownership_root:base
            path
            (`Assoc [ "generation", `Int 2 ])
        with
        | Error
            { renamed = false
            ; stage = KF.Directory_prepare
            ; failure = KF.Directory_chain_failed (KF.Non_directory_ancestor { path })
            } ->
          check string "retargeted symlink is identified" linked path
        | Error error ->
          failf
            "unexpected cached-chain error: %s"
            (KF.durable_write_error_to_string error)
        | Ok () -> fail "cached strict chain followed a retargeted symlink");
       check bool "outside target was not created" false
         (Sys.file_exists (Filename.concat outside "request.json")))
;;

let test_cached_owned_chain_reanchors_replaced_directory () =
  Eio_main.run
  @@ fun _env ->
  with_eio_guard
  @@ fun () ->
  KF.clear_dir_cache ();
  let base = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base)
    (fun () ->
       let active = Filename.concat base "active" in
       let retired = Filename.concat base "retired" in
       Unix.mkdir active 0o755;
       require_durable_ok
         "seed cached owned directory"
         (KF.save_json_durable_atomic
            ~ownership_root:base
            (Filename.concat active "first.json")
            (`Assoc []));
       Unix.rename active retired;
       Unix.mkdir active 0o755;
       let reanchored = Atomic.make false in
       require_durable_ok
         "write through replaced owned directory"
         (KF.For_testing.save_json_durable_atomic
            ~before_stage:(fun _ -> ())
            ~before_directory_fsync:(fun parent ->
              if String.equal parent base then Atomic.set reanchored true)
            ~ownership_root:base
            (Filename.concat active "second.json")
            (`Assoc []));
       check bool "replacement directory entry is re-anchored" true
         (Atomic.get reanchored))
;;

let test_cached_owned_prefix_rejects_uncached_descendant_escape () =
  Eio_main.run
  @@ fun _env ->
  with_eio_guard
  @@ fun () ->
  KF.clear_dir_cache ();
  let base = temp_dir () in
  let outside = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base; cleanup_dir outside)
    (fun () ->
       let linked = Filename.concat base "linked" in
       let retired = Filename.concat base "retired" in
       Unix.mkdir linked 0o755;
       require_durable_ok
         "seed cached owned prefix"
         (KF.save_json_durable_atomic
            ~ownership_root:base
            (Filename.concat linked "first.json")
            (`Assoc []));
       Unix.rename linked retired;
       Unix.symlink outside linked;
       let escaped_dir = Filename.concat outside "uncached" in
       let path = Filename.concat linked "uncached/second.json" in
       (match
          KF.save_json_durable_atomic
            ~ownership_root:base
            path
            (`Assoc [])
        with
        | Error
            { renamed = false
            ; stage = KF.Directory_prepare
            ; failure = KF.Directory_chain_failed (KF.Non_directory_ancestor { path })
            } ->
          check string "cached prefix symlink is identified" linked path
        | Error error ->
          failf
            "unexpected uncached-descendant error: %s"
            (KF.durable_write_error_to_string error)
        | Ok () -> fail "cached owned prefix escaped through an uncached descendant");
       check bool "outside descendant directory was not created" false
         (Sys.file_exists escaped_dir))
;;

let test_owned_remove_rejects_symlink_ancestor () =
  Eio_main.run
  @@ fun _env ->
  with_eio_guard
  @@ fun () ->
  let base = temp_dir () in
  let outside = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base; cleanup_dir outside)
    (fun () ->
       let outside_path = Filename.concat outside "request.json" in
       require_ok "seed outside removal target" (KF.save_atomic outside_path "outside");
       let linked = Filename.concat base "linked" in
       Unix.symlink outside linked;
       let path = Filename.concat linked "request.json" in
       (match KF.remove_file_durable ~ownership_root:base path with
        | Error { removed = false; failure = KF.Unlink, _ } -> ()
        | Error error ->
          failf
            "unexpected owned remove error: %s"
            (KF.durable_remove_error_to_string error)
        | Ok () -> fail "owned remove followed a symbolic-link ancestor");
       check bool "outside removal target remains" true (Sys.file_exists outside_path))
;;

let test_owned_temp_directory_trailing_separator_converges () =
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
       let temp_dir = Filename.concat base "staging" ^ Filename.dir_sep in
       let path = Filename.concat base "request.json" in
       require_durable_ok
         "owned trailing-separator temp directory"
         (KF.save_json_durable_atomic
            ~ownership_root:base
            ~temp_dir
            path
            (`Assoc [ "ok", `Bool true ])))
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

let test_pressure_observer_failure_preserves_post_rename_error () =
  Eio_main.run
  @@ fun _env ->
  with_eio_guard
  @@ fun () ->
  KF.clear_dir_cache ();
  let base = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base)
    (fun () ->
       let path = Filename.concat base "request.json" in
       with_strict_malformed_disk_pressure_cooldown (fun () ->
         match
           KF.For_testing.save_json_durable_atomic
             ~before_stage:(function
               | KF.Parent_directory_fsync_after_rename ->
                 raise (Unix.Unix_error (Unix.ENOSPC, "fsync", base))
               | _ -> ())
             path
             (`Assoc [])
         with
         | Error
             { renamed = true
             ; stage = KF.Parent_directory_fsync_after_rename
             ; failure = KF.Operation_failed _
             } ->
           check bool "rename remains visible" true (Sys.file_exists path)
         | Error error ->
           failf
             "pressure observer replaced post-rename error: %s"
             (KF.durable_write_error_to_string error)
         | Ok () -> fail "injected post-rename ENOSPC unexpectedly succeeded"))
;;

let test_pressure_observer_failure_preserves_post_unlink_error () =
  Eio_main.run
  @@ fun _env ->
  with_eio_guard
  @@ fun () ->
  let base = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base)
    (fun () ->
       let path = Filename.concat base "request.json" in
       require_ok "seed removable file" (KF.save_atomic path "payload");
       with_strict_malformed_disk_pressure_cooldown (fun () ->
         match
           KF.For_testing.remove_file_durable
             ~before_stage:(function
               | KF.Parent_directory_fsync ->
                 raise (Unix.Unix_error (Unix.ENOSPC, "fsync", base))
               | KF.Unlink -> ())
             path
         with
         | Error { removed = true; failure = KF.Parent_directory_fsync, _ } ->
           check bool "unlink remains visible" false (Sys.file_exists path)
         | Error error ->
           failf
             "pressure observer replaced post-unlink error: %s"
             (KF.durable_remove_error_to_string error)
         | Ok () -> fail "injected post-unlink ENOSPC unexpectedly succeeded"))
;;

let test_concurrent_owned_writers_share_uncached_preparation () =
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
       let target = Filename.concat base "contended" in
       let hook = blocking_hook base in
       let preparation_count = Atomic.make 0 in
       let waiter_first_validation = Atomic.make true in
       let waiter_validated, resolve_waiter_validated = Eio.Promise.create () in
       let allow_waiter_claim, resolve_allow_waiter_claim = Eio.Promise.create () in
       let owner_result, resolve_owner_result = Eio.Promise.create () in
       let waiter_result, resolve_waiter_result = Eio.Promise.create () in
       let count_preparation () =
         ignore (Atomic.fetch_and_add preparation_count 1 : int)
       in
       Eio.Switch.run
       @@ fun sw ->
       with_blocking_hook_release hook
       @@ fun () ->
       Eio.Fiber.fork ~sw (fun () ->
         let result =
           KDD.For_testing.ensure
             ~after_validation:(fun () -> ())
             ~before_prepare:count_preparation
             ~before_directory_fsync:(block_once hook (fun () -> ()))
             ~ownership_root:base
             target
         in
         Eio.Promise.resolve resolve_owner_result result);
       Eio.Promise.await hook.entered;
       Eio.Fiber.fork ~sw (fun () ->
         let result =
           KDD.For_testing.ensure
             ~after_validation:(fun () ->
               if Atomic.compare_and_set waiter_first_validation true false
               then (
                 Eio.Promise.resolve resolve_waiter_validated ();
                 Eio.Promise.await allow_waiter_claim))
             ~before_prepare:count_preparation
             ~before_directory_fsync:(fun _ -> ())
             ~ownership_root:base
             target
         in
         Eio.Promise.resolve resolve_waiter_result result);
       Eio.Promise.await waiter_validated;
       check int
         "cache miss does not retire the in-flight owner"
         1
         (Atomic.get preparation_count);
       Eio.Promise.resolve resolve_allow_waiter_claim ();
       release_blocking_hook hook;
       require_directory_lease "owned preparation owner" (Eio.Promise.await owner_result);
       require_directory_lease "owned preparation waiter" (Eio.Promise.await waiter_result);
       check int
         "both writers share one owned preparation"
         1
         (Atomic.get preparation_count))
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
            (match fault, Eio.Promise.await waiter_result with
             | Ordinary_failure, Error { stage = KF.Directory_prepare; _ } ->
               check bool "permanent failure is shared without retry" false
                 (Atomic.get waiter_prepared)
             | Ordinary_failure, Error error ->
               failf
                 "waiter observed the wrong shared failure: %s"
                 (KF.durable_write_error_to_string error)
             | Ordinary_failure, Ok () ->
               fail "waiter retried a permanent owner failure"
             | Cancellation, result ->
               require_durable_ok "waiter takeover" result;
               check bool "cancelled owner permits waiter retry" true
                 (Atomic.get waiter_prepared))))
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
            "symlink ancestor is rejected"
            `Quick
            test_symlink_ancestor_is_rejected
        ; test_case
            "cached owned chain rejects symlink retarget"
            `Quick
            test_cached_owned_chain_rejects_symlink_retarget
        ; test_case
            "cached owned chain reanchors replaced directory"
            `Quick
            test_cached_owned_chain_reanchors_replaced_directory
        ; test_case
            "cached owned prefix rejects uncached descendant escape"
            `Quick
            test_cached_owned_prefix_rejects_uncached_descendant_escape
        ; test_case
            "owned remove rejects symlink ancestor"
            `Quick
            test_owned_remove_rejects_symlink_ancestor
        ; test_case
            "owned temp directory trailing separator converges"
            `Quick
            test_owned_temp_directory_trailing_separator_converges
        ; test_case
            "retry re-anchors partial directory"
            `Quick
            test_retry_reanchors_partial_directory
        ; test_case
            "pressure observer preserves post-rename error"
            `Quick
            test_pressure_observer_failure_preserves_post_rename_error
        ; test_case
            "pressure observer preserves post-unlink error"
            `Quick
            test_pressure_observer_failure_preserves_post_unlink_error
        ] )
    ; ( "coordination"
      , [ test_case
            "concurrent owned writers share uncached preparation"
            `Quick
            test_concurrent_owned_writers_share_uncached_preparation
        ; test_case
            "owner failure is shared without retry storm"
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
