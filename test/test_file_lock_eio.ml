open Alcotest

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
  let key = File_lock_eio.Key.of_path path in
  let result =
    File_lock_eio.with_lock_blocking key (fun () ->
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
  let key = File_lock_eio.Key.of_path path in
  let result =
    File_lock_eio.with_lock_eio key (fun () ->
        incr calls;
        "ok")
  in
  check string "result" "ok" result;
  check int "single call" 1 !calls;
  check bool "lock table tracked" true (File_lock_eio.lock_count () >= 1)

let test_eio_and_blocking_contracts_share_ownership () =
  with_temp_path @@ fun path ->
  Eio_main.run @@ fun env ->
  let domain_mgr = Eio.Stdenv.domain_mgr env in
  let key = File_lock_eio.Key.of_path path in
  let inside = Atomic.make 0 in
  let max_inside = Atomic.make 0 in
  let enter with_lock =
    with_lock key (fun () ->
        let current = Atomic.fetch_and_add inside 1 + 1 in
        let rec record_max () =
          let previous = Atomic.get max_inside in
          if current > previous
             && not (Atomic.compare_and_set max_inside previous current)
          then record_max ()
        in
        record_max ();
        Unix.sleepf 0.005;
        let _previous = Atomic.fetch_and_add inside (-1) in
        ())
  in
  Eio.Fiber.both
    (fun () -> enter (fun key f -> File_lock_eio.with_lock_eio key f))
    (fun () ->
       Eio.Domain_manager.run domain_mgr (fun () ->
         enter File_lock_eio.with_lock_blocking));
  check int "Eio and blocking callers never overlap" 1 (Atomic.get max_inside)

let () =
  run "file_lock_eio"
    [
      ( "locks",
        [
          test_case "works without Eio context" `Quick test_with_lock_without_eio;
          test_case "acquire_flock_retry works without Eio context" `Quick
            test_acquire_flock_retry_without_eio;
          test_case "works inside Eio context" `Quick test_with_lock_inside_eio;
          test_case "Eio and blocking contracts share ownership" `Quick
            test_eio_and_blocking_contracts_share_ownership;
        ] );
    ]
