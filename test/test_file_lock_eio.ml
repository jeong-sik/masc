open Alcotest

let () =
  if Array.length Sys.argv = 3 && String.equal Sys.argv.(1) "--hold-durable-lock"
  then (
    let fd =
      Unix.openfile Sys.argv.(2) [ Unix.O_CREAT; Unix.O_WRONLY ] 0o644
    in
    Fun.protect
      ~finally:(fun () -> Unix.close fd)
      (fun () ->
        Unix.lockf fd Unix.F_LOCK 0;
        output_char stdout 'R';
        flush stdout;
        ignore (input_char stdin));
    exit 0)

let cleanup_if_exists path =
  if Sys.file_exists path then
    if Sys.is_directory path then
      Unix.rmdir path
    else
      Sys.remove path

let with_temp_path f =
  let base_dir = Filename.get_temp_dir_name () in
  let path =
    Filename.concat base_dir
      (Printf.sprintf "masc-file-lock-%d-%f"
         (Unix.getpid ()) (Unix.gettimeofday ()))
  in
  Fun.protect
    ~finally:(fun () ->
      cleanup_if_exists (path ^ ".lock");
      cleanup_if_exists path)
    (fun () -> f path)

let test_with_lock_without_eio () =
  with_temp_path @@ fun path ->
  let calls = ref 0 in
  let result =
    File_lock_eio.with_lock path (fun () ->
        incr calls;
        "ok")
  in
  check string "result" "ok" result;
  check int "single call" 1 !calls;
  check bool "lock file created" true (Sys.file_exists (path ^ ".lock"))

let test_acquire_flock_retry_without_eio () =
  with_temp_path @@ fun path ->
  let lock_path = path ^ ".lock" in
  let fd =
    File_lock_eio.acquire_flock_retry ~lock_path
      ~mode:[ Unix.O_CREAT; Unix.O_WRONLY ] ~perm:0o644
      ~max_attempts:1 ~caller:"test_file_lock_eio" ()
  in
  Fun.protect
    ~finally:(fun () -> File_lock_eio.release_flock_fd fd)
    (fun () ->
      check bool "lock file created" true (Sys.file_exists lock_path))

let test_with_lock_inside_eio () =
  with_temp_path @@ fun path ->
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let calls = ref 0 in
  let tracked_while_held = ref false in
  let result =
    File_lock_eio.with_lock path (fun () ->
        incr calls;
        tracked_while_held := File_lock_eio.lock_count () >= 1;
        "ok")
  in
  check string "result" "ok" result;
  check int "single call" 1 !calls;
  check bool "lock table tracked while held" true !tracked_while_held;
  check int "lock entry evicted on last release" 0
    (File_lock_eio.For_testing.holders_and_waiters ~lock_path:path)

let test_durable_lock_open_failure_is_typed () =
  with_temp_path @@ fun path ->
  let path = Filename.concat path "missing/target" in
  let body_ran = ref false in
  match
    File_lock_eio.with_durable_lock_observed
      ~lock_path:path
      (fun () -> body_ran := true)
  with
  | File_lock_eio.Body_completed _ ->
    fail "durable lock unexpectedly created a missing parent tree"
  | File_lock_eio.Lock_not_acquired error ->
    check bool "lock body did not run before acquisition" false !body_ran;
    check bool "failure phase is lock-file open" true
      (match error.File_lock_eio.phase with
       | File_lock_eio.Open_lock_file -> true
       | Acquire_process_lock | Release_process_lock -> false)

let test_durable_lock_release_failure_preserves_completed_value () =
  with_temp_path @@ fun lock_path ->
  let release_failure =
    { File_lock_eio.lock_path
    ; phase = File_lock_eio.Release_process_lock
    ; cause =
        { File_lock_eio.error = Unix.EIO
        ; operation = "injected_release_after_body"
        ; argument = lock_path
        }
    ; cleanup_failure = None
    }
  in
  match
    File_lock_eio.For_testing.with_durable_lock_observed_with_release_failure
      ~release_failure
      ~lock_path
      (fun () -> "completed")
  with
  | File_lock_eio.Lock_not_acquired error ->
    fail
      ("durable lock was not acquired: "
       ^ File_lock_eio.durable_lock_error_to_string error)
  | File_lock_eio.Body_completed { value; release_error } ->
    check string "completed body value survives release failure" "completed" value;
    check bool
      "release failure is exact"
      true
      (release_error = Some release_failure)
;;

let with_external_lock_holder lock_path f =
  let ready_read, ready_write = Unix.pipe () in
  let release_read, release_write = Unix.pipe () in
  let pid =
    Unix.create_process Sys.executable_name
      [| Sys.executable_name; "--hold-durable-lock"; lock_path |]
      release_read ready_write Unix.stderr
  in
  Unix.close ready_write;
  Unix.close release_read;
  let released = ref false in
  let release_holder () =
    if not !released then (
      released := true;
      Fun.protect
        ~finally:(fun () -> Unix.close release_write)
        (fun () ->
          check int "holder release signal" 1
            (Unix.write_substring release_write "X" 0 1)))
  in
  let rec wait_for_child () =
    match Unix.waitpid [] pid with
    | result -> result
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> wait_for_child ()
  in
  Fun.protect
    ~finally:(fun () ->
      release_holder ();
      ignore (wait_for_child ()))
    (fun () ->
      let ready = Bytes.create 1 in
      let count = Unix.read ready_read ready 0 1 in
      Unix.close ready_read;
      if count <> 1 || Bytes.get ready 0 <> 'R'
      then fail "lock holder did not start";
      f release_holder)

let test_durable_lock_wait_is_cancellable () =
  with_temp_path @@ fun path ->
  let lock_path = path ^ ".lock" in
  with_external_lock_holder lock_path @@ fun release_holder ->
  Eio_main.run @@ fun _env ->
  let started, signal_started = Eio.Promise.create () in
  let body_ran = ref false in
  let outcome =
    Eio.Fiber.first
      (fun () ->
        Eio.Promise.resolve signal_started ();
        match
          File_lock_eio.with_durable_lock ~lock_path (fun () -> body_ran := true)
        with
        | Ok () -> `Unexpected_admission
        | Error error -> `Failure (File_lock_eio.durable_lock_error_to_string error))
      (fun () ->
        Eio.Promise.await started;
        Eio.Fiber.yield ();
        release_holder ();
        `Cancelled_waiter)
  in
  check bool "contended body did not run" false !body_ran;
  match outcome with
  | `Cancelled_waiter -> ()
  | `Unexpected_admission -> fail "cross-process lock admitted while held"
  | `Failure detail -> fail ("lock wait failed instead of cancelling: " ^ detail)

let ran_once label = function
  | File_lock_eio.Lock_attempted
      (File_lock_eio.Body_completed { value = (); release_error = None }) -> ()
  | File_lock_eio.Lock_attempted (File_lock_eio.Body_completed { release_error = Some error; _ }) ->
    fail (label ^ ": release failed: " ^ File_lock_eio.durable_lock_error_to_string error)
  | File_lock_eio.Lock_attempted (File_lock_eio.Lock_not_acquired error) ->
    fail (label ^ ": " ^ File_lock_eio.durable_lock_error_to_string error)
  | File_lock_eio.Lock_held_elsewhere -> fail (label ^ ": a free lock was reported held")

let held_elsewhere label body_ran = function
  | File_lock_eio.Lock_held_elsewhere -> check bool (label ^ ": the body did not run") false !body_ran
  | File_lock_eio.Lock_attempted _ -> fail (label ^ ": a held lock was entered")

let test_try_durable_lock_never_waits () =
  with_temp_path @@ fun path ->
  let lock_path = path ^ ".lock" in
  Eio_main.run @@ fun _env ->
  let body_ran = ref false in
  ran_once "a free lock" (File_lock_eio.try_with_durable_lock_observed ~lock_path (fun () -> ()));
  let entered, signal_entered = Eio.Promise.create () in
  let leave, signal_leave = Eio.Promise.create () in
  Eio.Fiber.both
    (fun () ->
      match File_lock_eio.with_durable_lock ~lock_path (fun () ->
          Eio.Promise.resolve signal_entered ();
          Eio.Promise.await leave) with
      | Ok () -> ()
      | Error error -> fail (File_lock_eio.durable_lock_error_to_string error))
    (fun () ->
      Eio.Promise.await entered;
      held_elsewhere "held by a fiber of this process" body_ran
        (File_lock_eio.try_with_durable_lock_observed ~lock_path (fun () -> body_ran := true));
      Eio.Promise.resolve signal_leave ());
  ran_once "the lock once released" (File_lock_eio.try_with_durable_lock_observed ~lock_path (fun () -> ()))

let test_try_durable_lock_held_by_another_process () =
  with_temp_path @@ fun path ->
  let lock_path = path ^ ".lock" in
  with_external_lock_holder lock_path @@ fun _release_holder ->
  Eio_main.run @@ fun _env ->
  let body_ran = ref false in
  held_elsewhere "held by another process" body_ran
    (File_lock_eio.try_with_durable_lock_observed ~lock_path (fun () -> body_ran := true))

exception Test_lock_cancelled

let test_with_lock_symlink_convergence_and_cancelled_release () =
  let root = Filename.temp_dir "masc-file-lock-alias-" "" in
  let real_dir = Filename.concat root "real" in
  let alias_dir = Filename.concat root "alias" in
  Unix.mkdir real_dir 0o755;
  Unix.symlink real_dir alias_dir;
  let rec rm_tree p =
    match Unix.lstat p with
    | exception Unix.Unix_error _ -> ()
    | { Unix.st_kind = Unix.S_DIR; _ } ->
      Array.iter (fun e -> rm_tree (Filename.concat p e)) (Sys.readdir p);
      Unix.rmdir p
    | _ -> Unix.unlink p
  in
  Fun.protect
    ~finally:(fun () -> rm_tree root)
    (fun () ->
       let real_path = Filename.concat real_dir "target.json" in
       let alias_path = Filename.concat alias_dir "target.json" in
       Eio_main.run @@ fun _env ->
       let entered, resolve_entered = Eio.Promise.create () in
       let block, _resolve_block = Eio.Promise.create () in
       (try
          Eio.Switch.run @@ fun sw ->
          Eio.Fiber.fork ~sw (fun () ->
            File_lock_eio.with_lock real_path (fun () ->
              check int "alias shares active lock holder count" 1
                (File_lock_eio.For_testing.holders_and_waiters ~lock_path:alias_path);
              Eio.Promise.resolve resolve_entered ();
              Eio.Promise.await block));
          Eio.Promise.await entered;
          raise Test_lock_cancelled
        with
        | Test_lock_cancelled -> ());
       check int "zero active holders after cancellation" 0
         (File_lock_eio.For_testing.holders_and_waiters ~lock_path:real_path);
       let acquired_after_cancel =
         File_lock_eio.with_lock alias_path (fun () -> "reacquired")
       in
       check string "lock reusable immediately after cancellation"
         "reacquired" acquired_after_cancel)

let test_durable_lock_contended_wait_cooperates_until_release () =
  with_temp_path @@ fun path ->
  let lock_path = path ^ ".lock" in
  with_external_lock_holder lock_path @@ fun release_holder ->
  let observed_retries = ref None in
  let prev_hook = Atomic.get File_lock_eio.on_lock_attempt_fn in
  Atomic.set File_lock_eio.on_lock_attempt_fn
    (fun ~caller ~retries ~elapsed_s:_ ~outcome ->
      if String.equal caller "File_lock_eio.durable" && String.equal outcome "acquired"
      then observed_retries := Some retries);
  Fun.protect
    ~finally:(fun () -> Atomic.set File_lock_eio.on_lock_attempt_fn prev_hook)
    (fun () ->
      Eio_main.run @@ fun env ->
      let clock = Eio.Stdenv.clock env in
      let waiting, resolve_waiting = Eio.Promise.create () in
      let body_ran = ref false in
      Eio.Fiber.both
        (fun () ->
          Eio.Promise.resolve resolve_waiting ();
          match
            File_lock_eio.with_durable_lock ~lock_path (fun () ->
              body_ran := true;
              "acquired")
          with
          | Ok v -> check string "acquired after external release" "acquired" v
          | Error error -> fail (File_lock_eio.durable_lock_error_to_string error))
        (fun () ->
          Eio.Promise.await waiting;
          Eio.Time.sleep clock 0.025;
          release_holder ());
      check bool "durable lock body ran after release" true !body_ran;
      match !observed_retries with
      | Some r -> check bool "observed at least one paced retry" true (r >= 1)
      | None -> fail "durable lock attempt hook did not fire")

let test_durable_lock_reopens_after_unlinked_inode () =
  with_temp_path @@ fun path ->
  let lock_path = path ^ ".lock" in
  with_external_lock_holder lock_path @@ fun release_holder ->
  let initial_ino = (Unix.lstat lock_path).Unix.st_ino in
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  let waiting, signal_waiting = Eio.Promise.create () in
  let body_ran = ref false in
  let locked_current_inode = ref false in
  let child_saw_contended = ref false in
  Eio.Fiber.both
    (fun () ->
       Eio.Promise.resolve signal_waiting ();
       match
         File_lock_eio.with_durable_lock ~lock_path (fun () ->
           body_ran := true;
           let cur_stat = Unix.lstat lock_path in
           locked_current_inode := cur_stat.Unix.st_ino <> initial_ino;
           (* Confirm from a separate OS process that the newly opened
              directory entry at [lock_path] actually holds the POSIX lock. *)
           let pid =
             Unix.create_process
               "python3"
               [| "python3"
                ; "-c"
                ; "import fcntl, os, sys; fd = os.open(sys.argv[1], os.O_WRONLY); fcntl.lockf(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)"
                ; lock_path
               |]
               Unix.stdin
               Unix.stdout
               Unix.stderr
           in
           let rec wait () =
             match Unix.waitpid [] pid with
             | _, status -> status
             | exception Unix.Unix_error (Unix.EINTR, _, _) -> wait ()
           in
           match wait () with
           | Unix.WEXITED 0 -> child_saw_contended := false
           | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ ->
             child_saw_contended := true)
       with
       | Ok () -> ()
       | Error error -> fail (File_lock_eio.durable_lock_error_to_string error))
    (fun () ->
       Eio.Promise.await waiting;
       Eio.Time.sleep clock 0.025;
       Unix.unlink lock_path;
       release_holder ());
  check bool "body ran after stale inode retry" true !body_ran;
  check bool "reopened fresh inode at lock_path" true !locked_current_inode;
  check bool "separate process saw fresh inode locked" true !child_saw_contended

let test_durable_lock_rejects_symlink_without_spinning () =
  with_temp_path @@ fun path ->
  let target = path ^ ".target" in
  let lock_path = path ^ ".lock" in
  let fd = Unix.openfile target [ Unix.O_CREAT; Unix.O_WRONLY; Unix.O_CLOEXEC ] 0o600 in
  Unix.close fd;
  Unix.symlink target lock_path;
  Fun.protect
    ~finally:(fun () ->
      (try Unix.unlink lock_path with Unix.Unix_error _ -> ());
      (try Unix.unlink target with Unix.Unix_error _ -> ()))
    (fun () ->
       (match File_lock_eio.with_durable_lock ~lock_path (fun () -> ()) with
        | Ok () -> fail "symlink lock_path must fail closed"
        | Error err ->
          check bool "symlink returns ELOOP immediately" true (err.cause.error = Unix.ELOOP));
       match File_lock_eio.try_with_durable_lock_observed ~lock_path (fun () -> ()) with
       | File_lock_eio.Lock_attempted (File_lock_eio.Lock_not_acquired err) ->
         check bool "try_with_durable_lock returns ELOOP immediately" true
           (err.cause.error = Unix.ELOOP)
       | File_lock_eio.Lock_held_elsewhere
       | File_lock_eio.Lock_attempted (File_lock_eio.Body_completed _) ->
         fail "try_with_durable_lock on symlink must fail with ELOOP")

let test_unlink_if_unheld_preserves_bsd_flock_liveness_holder () =
  with_temp_path @@ fun path ->
  let lock_path = path ^ ".lock" in
  let fd = Unix.openfile lock_path [ Unix.O_CREAT; Unix.O_WRONLY; Unix.O_CLOEXEC ] 0o600 in
  Unix.close fd;
  Fun.protect
    ~finally:(fun () ->
      try Unix.unlink lock_path with Unix.Unix_error _ -> ())
    (fun () ->
       (match
          File_lock_eio.try_with_liveness_lock_observed ~lock_path (fun () ->
            match
              File_lock_eio.unlink_if_unheld
                ~lock_path
                ~target_absent:(fun () -> true)
            with
            | File_lock_eio.Stale_lock_kept_held ->
              check bool "exclusive liveness lock file preserved on disk" true
                (Sys.file_exists lock_path)
            | File_lock_eio.Stale_lock_removed
            | File_lock_eio.Stale_lock_kept_target_present
            | File_lock_eio.Stale_lock_already_absent
            | File_lock_eio.Stale_lock_cleanup_failed _ ->
              fail "unlink_if_unheld must keep file held by exclusive BSD flock")
        with
        | File_lock_eio.Lock_attempted (File_lock_eio.Body_completed { value = (); release_error = None }) -> ()
        | File_lock_eio.Lock_held_elsewhere
        | File_lock_eio.Lock_attempted _ ->
          fail "expected exclusive liveness lock acquisition to succeed");
       (match
          File_lock_eio.try_with_shared_liveness_lock_observed ~lock_path (fun () ->
            match
              File_lock_eio.unlink_if_unheld
                ~lock_path
                ~target_absent:(fun () -> true)
            with
            | File_lock_eio.Stale_lock_kept_held ->
              check bool "shared liveness lock file preserved on disk" true
                (Sys.file_exists lock_path)
            | File_lock_eio.Stale_lock_removed
            | File_lock_eio.Stale_lock_kept_target_present
            | File_lock_eio.Stale_lock_already_absent
            | File_lock_eio.Stale_lock_cleanup_failed _ ->
              fail "unlink_if_unheld must keep file held by shared BSD flock")
        with
        | File_lock_eio.Lock_attempted (File_lock_eio.Body_completed { value = (); release_error = None }) -> ()
        | File_lock_eio.Lock_held_elsewhere
        | File_lock_eio.Lock_attempted _ ->
          fail "expected shared liveness lock acquisition to succeed");
       match File_lock_eio.unlink_if_unheld ~lock_path ~target_absent:(fun () -> true) with
       | File_lock_eio.Stale_lock_removed ->
         check bool "unheld lock removed after liveness flock release" false
           (Sys.file_exists lock_path)
       | File_lock_eio.Stale_lock_kept_held
       | File_lock_eio.Stale_lock_kept_target_present
       | File_lock_eio.Stale_lock_already_absent
       | File_lock_eio.Stale_lock_cleanup_failed _ ->
         fail "unlink_if_unheld must remove stale lock once liveness flock is released")

let () =
  run "file_lock_eio"
    [
      ( "locks",
        [
          test_case "works without Eio context" `Quick test_with_lock_without_eio;
          test_case "acquire_flock_retry works without Eio context" `Quick
            test_acquire_flock_retry_without_eio;
          test_case "works inside Eio context" `Quick test_with_lock_inside_eio;
          test_case "durable lock open failure is typed" `Quick
            test_durable_lock_open_failure_is_typed;
          test_case "durable lock release failure preserves body value" `Quick
            test_durable_lock_release_failure_preserves_completed_value;
          test_case "durable cross-process wait is cancellable" `Quick
            test_durable_lock_wait_is_cancellable;
          test_case "a durable lock attempt never waits" `Quick
            test_try_durable_lock_never_waits;
          test_case "a durable lock attempt sees another process" `Quick
            test_try_durable_lock_held_by_another_process;
          test_case "with_lock symlink convergence and cancelled release" `Quick
            test_with_lock_symlink_convergence_and_cancelled_release;
          test_case "durable cross-process wait cooperates until release" `Quick
            test_durable_lock_contended_wait_cooperates_until_release;
          test_case "durable lock reopens fresh inode when stale inode is unlinked" `Quick
            test_durable_lock_reopens_after_unlinked_inode;
          test_case "durable lock rejects symlink lock_path without spinning" `Quick
            test_durable_lock_rejects_symlink_without_spinning;
          test_case "unlink_if_unheld preserves file held by BSD flock liveness lock" `Quick
            test_unlink_if_unheld_preserves_bsd_flock_liveness_holder;
        ] );
    ]
