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
  let result =
    File_lock_eio.with_lock path (fun () ->
        incr calls;
        "ok")
  in
  check string "result" "ok" result;
  check int "single call" 1 !calls;
  check bool "lock table tracked" true (File_lock_eio.lock_count () >= 1)

let test_durable_lock_open_failure_is_typed () =
  with_temp_path @@ fun path ->
  let path = Filename.concat path "missing/target" in
  match File_lock_eio.with_durable_lock ~lock_path:path (fun () -> ()) with
  | Ok () -> fail "durable lock unexpectedly created a missing parent tree"
  | Error error ->
    check bool "failure phase is lock-file open" true
      (match error.File_lock_eio.phase with
       | File_lock_eio.Open_lock_file -> true
       | Acquire_process_lock | Release_process_lock -> false)

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
          test_case "durable cross-process wait is cancellable" `Quick
            test_durable_lock_wait_is_cancellable;
        ] );
    ]
