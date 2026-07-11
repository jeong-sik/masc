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

let with_descriptor_lock directory ~segment ~path f =
  File_lock_eio.with_anchored_file_lock
    ~path
    ~directory
    ~name:segment
    ~perm:0o600
    f
;;

let test_descriptor_lock_hard_link_alias_serializes_and_recovers () =
  with_temp_path @@ fun path ->
  Unix.mkdir path 0o700;
  let primary_path = Filename.concat path "state.lock" in
  let alias_path = Filename.concat path "alias.lock" in
  Fun.protect
    ~finally:(fun () ->
      cleanup_if_exists alias_path;
      cleanup_if_exists primary_path)
    (fun () ->
      let module Dir = Fs_compat.Anchored_dir in
      let primary =
        match Dir.Segment.of_string "state.lock" with
        | Ok segment -> segment
        | Error error -> Alcotest.fail (Dir.Segment.error_to_string error)
      in
      let alias =
        match Dir.Segment.of_string "alias.lock" with
        | Ok segment -> segment
        | Error error -> Alcotest.fail (Dir.Segment.error_to_string error)
      in
      Dir.with_open_root path @@ fun first ->
      let bootstrap = Dir.open_lock_file first ~name:primary ~perm:0o600 in
      Dir.close_lock_file bootstrap;
      Unix.link primary_path alias_path;
      Eio_main.run @@ fun _env ->
      Eio_guard.enable ();
      Fun.protect
        ~finally:Eio_guard.disable
        (fun () ->
          Eio.Switch.run @@ fun sw ->
          let first_entered, resolve_first_entered = Eio.Promise.create () in
          let release_first, resolve_release_first = Eio.Promise.create () in
          let second_attempted, resolve_second_attempted = Eio.Promise.create () in
          let second_entered, resolve_second_entered = Eio.Promise.create () in
          Eio.Fiber.fork ~sw (fun () ->
            with_descriptor_lock first ~segment:primary ~path:primary_path (fun () ->
              Eio.Promise.resolve resolve_first_entered ();
              Eio.Promise.await release_first));
          Eio.Promise.await first_entered;
          Eio.Fiber.fork ~sw (fun () ->
            Eio.Promise.resolve resolve_second_attempted ();
            with_descriptor_lock first ~segment:alias ~path:alias_path (fun () ->
              Eio.Promise.resolve resolve_second_entered ()));
          Eio.Promise.await second_attempted;
          Eio.Fiber.yield ();
          Alcotest.(check bool)
            "hard-link alias body waits for the first holder"
            true
            (Option.is_none (Eio.Promise.peek second_entered));
          Eio.Promise.resolve resolve_release_first ();
          Eio.Promise.await second_entered;
          (match
             with_descriptor_lock first ~segment:primary ~path:primary_path (fun () ->
               failwith "body failure")
           with
           | exception Failure "body failure" -> ()
           | () -> Alcotest.fail "expected body failure");
          with_descriptor_lock first ~segment:alias ~path:alias_path (fun () -> ())))

let test_descriptor_lock_cancellation_closes_before_reacquire () =
  with_temp_path @@ fun path ->
  Unix.mkdir path 0o700;
  let lock_path = Filename.concat path "state.lock" in
  Fun.protect
    ~finally:(fun () -> cleanup_if_exists lock_path)
    (fun () ->
      let module Dir = Fs_compat.Anchored_dir in
      let segment =
        match Dir.Segment.of_string "state.lock" with
        | Ok segment -> segment
        | Error error -> Alcotest.fail (Dir.Segment.error_to_string error)
      in
      Dir.with_open_root path @@ fun root ->
      Eio_main.run @@ fun env ->
      Eio_guard.enable ();
      Fun.protect
        ~finally:Eio_guard.disable
        (fun () ->
          let entered, resolve_entered = Eio.Promise.create () in
          let completed =
            Eio.Fiber.first
              (fun () ->
                with_descriptor_lock root ~segment ~path:lock_path (fun () ->
                  Eio.Promise.resolve resolve_entered ();
                  Eio.Time.sleep (Eio.Stdenv.clock env) 60.0))
              (fun () -> Eio.Promise.await entered)
          in
          check unit "cancelling peer completed" () completed;
          with_descriptor_lock root ~segment ~path:lock_path (fun () -> ())))

let test_anchored_lock_and_read_reject_nonregular_entries () =
  with_temp_path @@ fun path ->
  Unix.mkdir path 0o700;
  let fifo_path = Filename.concat path "state.fifo" in
  let target_path = Filename.concat path "target" in
  let link_path = Filename.concat path "state.link" in
  Unix.mkfifo fifo_path 0o600;
  let output = open_out_bin target_path in
  output_string output "target";
  close_out output;
  Unix.symlink "target" link_path;
  Fun.protect
    ~finally:(fun () ->
      cleanup_if_exists link_path;
      cleanup_if_exists target_path;
      cleanup_if_exists fifo_path)
    (fun () ->
      let module Dir = Fs_compat.Anchored_dir in
      let fifo =
        match Dir.Segment.of_string "state.fifo" with
        | Ok segment -> segment
        | Error error -> Alcotest.fail (Dir.Segment.error_to_string error)
      in
      let link =
        match Dir.Segment.of_string "state.link" with
        | Ok segment -> segment
        | Error error -> Alcotest.fail (Dir.Segment.error_to_string error)
      in
      Dir.with_open_root path @@ fun root ->
      (match Dir.read_file root fifo with
       | exception Unix.Unix_error (Unix.EINVAL, _, _) -> ()
       | _ -> Alcotest.fail "FIFO was accepted as an anchored readable file");
      (match Dir.open_lock_file root ~name:fifo ~perm:0o600 with
       | exception Unix.Unix_error (Unix.EINVAL, _, _) -> ()
       | _ -> Alcotest.fail "FIFO was accepted as an anchored lock file");
      match Dir.open_lock_file root ~name:link ~perm:0o600 with
      | exception Unix.Unix_error (Unix.ELOOP, _, _) -> ()
      | _ -> Alcotest.fail "symlink was accepted as an anchored lock file")

let () =
  run "file_lock_eio"
    [
      ( "locks",
        [
          test_case "works without Eio context" `Quick test_with_lock_without_eio;
          test_case "acquire_flock_retry works without Eio context" `Quick
            test_acquire_flock_retry_without_eio;
          test_case "works inside Eio context" `Quick test_with_lock_inside_eio;
          test_case
            "hard-link alias serializes and recovers after failure"
            `Quick
            test_descriptor_lock_hard_link_alias_serializes_and_recovers;
          test_case
            "cancellation closes descriptor lock before re-acquire"
            `Quick
            test_descriptor_lock_cancellation_closes_before_reacquire;
          test_case
            "anchored lock and read reject FIFO and symlink entries"
            `Quick
            test_anchored_lock_and_read_reject_nonregular_entries;
        ] );
    ]
