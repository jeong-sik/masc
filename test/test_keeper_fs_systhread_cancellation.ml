open Alcotest

module KF = Masc.Keeper_fs

exception Requested_cancel

type blocking_hook =
  { entered : unit Eio.Promise.t
  ; resolve_entered : unit Eio.Promise.u
  ; armed : bool Atomic.t
  ; mutex : Stdlib.Mutex.t
  ; condition : Stdlib.Condition.t
  ; mutable released : bool
  }

type operation_outcome =
  | Cancelled
  | Returned_ok
  | Returned_error of string
  | Raised of string

let blocking_hook () =
  let entered, resolve_entered = Eio.Promise.create () in
  { entered
  ; resolve_entered
  ; armed = Atomic.make true
  ; mutex = Stdlib.Mutex.create ()
  ; condition = Stdlib.Condition.create ()
  ; released = false
  }
;;

let release hook =
  Stdlib.Mutex.protect hook.mutex (fun () ->
    if not hook.released
    then (
      hook.released <- true;
      Stdlib.Condition.broadcast hook.condition))
;;

let with_release hook f = Fun.protect ~finally:(fun () -> release hook) f

let block_once hook =
  if Atomic.compare_and_set hook.armed true false
  then (
    Eio.Promise.resolve hook.resolve_entered ();
    Stdlib.Mutex.lock hook.mutex;
    Fun.protect
      ~finally:(fun () -> Stdlib.Mutex.unlock hook.mutex)
      (fun () ->
         while not hook.released do
           Stdlib.Condition.wait hook.condition hook.mutex
         done))
;;

let temp_dir () =
  let dir = Filename.temp_file "test_keeper_fs_systhread_cancel_" "" in
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

let with_eio_guard f =
  Eio_guard.enable ();
  Fun.protect ~finally:Eio_guard.disable f
;;

let require_write_ok label = function
  | Ok () -> ()
  | Error error -> failf "%s: %s" label (KF.durable_write_error_to_string error)
;;

let require_remove_ok label = function
  | Ok () -> ()
  | Error error -> failf "%s: %s" label (KF.durable_remove_error_to_string error)
;;

let expect_cancelled = function
  | Cancelled -> ()
  | Returned_ok -> fail "cancelled operation returned success"
  | Returned_error error -> failf "cancelled operation returned error: %s" error
  | Raised error -> failf "cancelled operation raised an unexpected exception: %s" error
;;

let test_write_context_cancellation_is_not_swallowed () =
  Eio_main.run
  @@ fun _env ->
  with_eio_guard
  @@ fun () ->
  KF.clear_dir_cache ();
  let base = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base)
    (fun () ->
       let path = Filename.concat base "record.json" in
       require_write_ok "seed write" (KF.save_json_durable_atomic path (`Assoc []));
       let hook = blocking_hook () in
       let context, resolve_context = Eio.Promise.create () in
       let result, resolve_result = Eio.Promise.create () in
       Eio.Switch.run
       @@ fun sw ->
       with_release hook
       @@ fun () ->
       Eio.Fiber.fork ~sw (fun () ->
         let outcome =
           try
             Eio.Cancel.sub (fun cancel_context ->
               Eio.Promise.resolve resolve_context cancel_context;
               match
                 KF.For_testing.save_json_durable_atomic
                   ~before_stage:(function
                     | KF.Payload_write -> block_once hook
                     | _ -> ())
                   path
                   (`Assoc [ "version", `Int 2 ])
               with
               | Ok () -> Returned_ok
               | Error error -> Returned_error (KF.durable_write_error_to_string error))
           with
           | Eio.Cancel.Cancelled _ -> Cancelled
           | exn -> Raised (Printexc.to_string exn)
         in
         Eio.Promise.resolve resolve_result outcome);
       let cancel_context = Eio.Promise.await context in
       Eio.Promise.await hook.entered;
       Eio.Cancel.cancel cancel_context Requested_cancel;
       release hook;
       expect_cancelled (Eio.Promise.await result);
       check bool "completed write remains visible" true (Sys.file_exists path))
;;

let test_remove_context_cancellation_is_not_swallowed () =
  Eio_main.run
  @@ fun _env ->
  with_eio_guard
  @@ fun () ->
  KF.clear_dir_cache ();
  let base = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base)
    (fun () ->
       let path = Filename.concat base "record.json" in
       require_write_ok "seed remove target"
         (KF.save_json_durable_atomic path (`Assoc []));
       let hook = blocking_hook () in
       let context, resolve_context = Eio.Promise.create () in
       let result, resolve_result = Eio.Promise.create () in
       Eio.Switch.run
       @@ fun sw ->
       with_release hook
       @@ fun () ->
       Eio.Fiber.fork ~sw (fun () ->
         let outcome =
           try
             Eio.Cancel.sub (fun cancel_context ->
               Eio.Promise.resolve resolve_context cancel_context;
               match
                 KF.For_testing.remove_file_durable
                   ~before_stage:(function
                     | KF.Unlink -> block_once hook
                     | KF.Parent_directory_fsync -> ())
                   path
               with
               | Ok () -> Returned_ok
               | Error error -> Returned_error (KF.durable_remove_error_to_string error))
           with
           | Eio.Cancel.Cancelled _ -> Cancelled
           | exn -> Raised (Printexc.to_string exn)
         in
         Eio.Promise.resolve resolve_result outcome);
       let cancel_context = Eio.Promise.await context in
       Eio.Promise.await hook.entered;
       Eio.Cancel.cancel cancel_context Requested_cancel;
       release hook;
       expect_cancelled (Eio.Promise.await result);
       check bool "completed unlink remains visible" false (Sys.file_exists path))
;;

let test_durable_operations_work_before_eio_guard_enable () =
  Eio_guard.disable ();
  KF.clear_dir_cache ();
  let base = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base)
    (fun () ->
       let path = Filename.concat base "standalone/record.json" in
       require_write_ok "standalone durable write"
         (KF.save_json_durable_atomic path (`Assoc []));
       require_remove_ok "standalone durable remove" (KF.remove_file_durable path))
;;

let () =
  run
    "Keeper_fs systhread cancellation"
    [ ( "durability",
        [ test_case
            "write context cancellation propagates"
            `Quick
            test_write_context_cancellation_is_not_swallowed
        ; test_case
            "remove context cancellation propagates"
            `Quick
            test_remove_context_cancellation_is_not_swallowed
        ; test_case
            "pre-Eio durable fallback"
            `Quick
            test_durable_operations_work_before_eio_guard_enable
        ] )
    ]
;;
