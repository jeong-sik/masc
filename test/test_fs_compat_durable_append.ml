open Alcotest

let with_durable_append_fd ~original f =
  let path = Filename.temp_file "masc_durable_append_" ".log" in
  let output = open_out_bin path in
  output_string output original;
  close_out output;
  let fd =
    Unix.openfile path [ Unix.O_RDWR; Unix.O_APPEND; Unix.O_CLOEXEC ] 0o600
  in
  Fun.protect
    ~finally:(fun () ->
      Unix.close fd;
      Sys.remove path)
    (fun () -> f path fd)
;;

let check_unix_failure ~label ~operation ~error = function
  | Fs_compat.Unix_error failure ->
    check bool (label ^ " operation") true (failure.operation = operation);
    check bool (label ^ " Unix.error") true (failure.error = error)
  | Fs_compat.No_write_progress -> fail (label ^ " lost the typed Unix.error")
;;

let partial_write_then_error ~path error =
  let write_calls = ref 0 in
  fun fd bytes offset remaining ->
    incr write_calls;
    if !write_calls = 1
    then Unix.single_write fd bytes offset (min 3 remaining)
    else raise (Unix.Unix_error (error, "injected_write", path))
;;

let test_success_fsyncs () =
  with_durable_append_fd ~original:"before"
  @@ fun path fd ->
  let fsync_calls = ref 0 in
  let io : Fs_compat.durable_append_io_for_testing =
    { write = Unix.write
    ; ftruncate = Unix.ftruncate
    ; fsync =
        (fun fd ->
          incr fsync_calls;
          Unix.fsync fd)
    }
  in
  let original_length = (Unix.fstat fd).Unix.st_size in
  (match
     Fs_compat.append_fd_durable_for_testing
       ~io
       ~fd
       ~original_length
       "-after"
   with
   | Ok () -> ()
   | Error error -> fail (Fs_compat.durable_append_error_to_string error));
  check int "successful append fsync count" 1 !fsync_calls;
  check string "successful durable append" "before-after" (Fs_compat.load_file path)
;;

let test_partial_write_rolls_back error =
  with_durable_append_fd ~original:"stable"
  @@ fun path fd ->
  let truncate_calls = ref 0 in
  let fsync_calls = ref 0 in
  let io : Fs_compat.durable_append_io_for_testing =
    { write = partial_write_then_error ~path error
    ; ftruncate =
        (fun fd length ->
          incr truncate_calls;
          Unix.ftruncate fd length)
    ; fsync =
        (fun fd ->
          incr fsync_calls;
          Unix.fsync fd)
    }
  in
  let original_length = (Unix.fstat fd).Unix.st_size in
  (match
     Fs_compat.append_fd_durable_for_testing
       ~io
       ~fd
       ~original_length
       "-partial-suffix"
   with
   | Ok () -> fail "partial write unexpectedly succeeded"
   | Error { append_failure; rollback_failures } ->
     check_unix_failure
       ~label:"append failure"
       ~operation:Fs_compat.Write
       ~error
       append_failure;
     check int "rollback failures" 0 (List.length rollback_failures));
  check int "rollback truncate count" 1 !truncate_calls;
  check int "rollback fsync count" 1 !fsync_calls;
  check int "original file length restored" original_length (Unix.fstat fd).Unix.st_size;
  check string "partial suffix removed" "stable" (Fs_compat.load_file path)
;;

let test_partial_enospc_rolls_back () = test_partial_write_rolls_back Unix.ENOSPC
let test_partial_eio_rolls_back () = test_partial_write_rolls_back Unix.EIO

let test_append_fsync_failure_rolls_back () =
  with_durable_append_fd ~original:"stable"
  @@ fun path fd ->
  let fsync_calls = ref 0 in
  let io : Fs_compat.durable_append_io_for_testing =
    { write = Unix.write
    ; ftruncate = Unix.ftruncate
    ; fsync =
        (fun fd ->
          incr fsync_calls;
          if !fsync_calls = 1
          then raise (Unix.Unix_error (Unix.EIO, "injected_append_fsync", path))
          else Unix.fsync fd)
    }
  in
  let original_length = (Unix.fstat fd).Unix.st_size in
  (match
     Fs_compat.append_fd_durable_for_testing
       ~io
       ~fd
       ~original_length
       "-complete-but-not-durable"
   with
   | Ok () -> fail "failed append fsync unexpectedly succeeded"
   | Error { append_failure; rollback_failures } ->
     check_unix_failure
       ~label:"append fsync failure"
       ~operation:Fs_compat.Append_fsync
       ~error:Unix.EIO
       append_failure;
     check int "rollback failures" 0 (List.length rollback_failures));
  check int "append and rollback fsync calls" 2 !fsync_calls;
  check int "original file length restored" original_length (Unix.fstat fd).Unix.st_size;
  check string "complete suffix rolled back" "stable" (Fs_compat.load_file path)
;;

let test_rollback_truncate_failure_is_explicit_and_still_fsyncs () =
  with_durable_append_fd ~original:"stable"
  @@ fun path fd ->
  let rollback_fsync_calls = ref 0 in
  let io : Fs_compat.durable_append_io_for_testing =
    { write = partial_write_then_error ~path Unix.ENOSPC
    ; ftruncate =
        (fun _fd _length ->
          raise (Unix.Unix_error (Unix.EIO, "injected_ftruncate", path)))
    ; fsync =
        (fun fd ->
          incr rollback_fsync_calls;
          Unix.fsync fd)
    }
  in
  let original_length = (Unix.fstat fd).Unix.st_size in
  (match
     Fs_compat.append_fd_durable_for_testing
       ~io
       ~fd
       ~original_length
       "-partial-suffix"
   with
   | Ok () -> fail "append with failed rollback unexpectedly succeeded"
   | Error { append_failure; rollback_failures } ->
     check_unix_failure
       ~label:"original append failure"
       ~operation:Fs_compat.Write
       ~error:Unix.ENOSPC
       append_failure;
     (match rollback_failures with
      | [ rollback_failure ] ->
        check_unix_failure
          ~label:"rollback truncate failure"
          ~operation:Fs_compat.Rollback_truncate
          ~error:Unix.EIO
          rollback_failure
      | failures ->
        failf "expected one rollback failure, got %d" (List.length failures)));
  check int "rollback fsync still attempted" 1 !rollback_fsync_calls
;;

let test_rollback_fsync_failure_is_explicit () =
  with_durable_append_fd ~original:"stable"
  @@ fun path fd ->
  let io : Fs_compat.durable_append_io_for_testing =
    { write = partial_write_then_error ~path Unix.ENOSPC
    ; ftruncate = Unix.ftruncate
    ; fsync =
        (fun _fd -> raise (Unix.Unix_error (Unix.EIO, "injected_fsync", path)))
    }
  in
  let original_length = (Unix.fstat fd).Unix.st_size in
  (match
     Fs_compat.append_fd_durable_for_testing
       ~io
       ~fd
       ~original_length
       "-partial-suffix"
   with
   | Ok () -> fail "append with failed rollback fsync unexpectedly succeeded"
   | Error { append_failure; rollback_failures } ->
     check_unix_failure
       ~label:"original append failure"
       ~operation:Fs_compat.Write
       ~error:Unix.ENOSPC
       append_failure;
     (match rollback_failures with
      | [ rollback_failure ] ->
        check_unix_failure
          ~label:"rollback fsync failure"
          ~operation:Fs_compat.Rollback_fsync
          ~error:Unix.EIO
          rollback_failure
      | failures ->
        failf "expected one rollback failure, got %d" (List.length failures)));
  check int "truncate restored original length" original_length (Unix.fstat fd).Unix.st_size;
  check string "partial suffix removed before failed fsync" "stable" (Fs_compat.load_file path)
;;

let with_temp_jsonl original f =
  let path = Filename.temp_file "masc_private_jsonl_" ".jsonl" in
  let output = open_out_bin path in
  output_string output original;
  close_out output;
  Fun.protect
    ~finally:(fun () ->
      Sys.remove path;
      let lock_path = path ^ ".lock" in
      if Sys.file_exists lock_path then Sys.remove lock_path)
    (fun () -> f path)
;;

let test_private_jsonl_first_creation_is_durable () =
  let dir = Filename.temp_file "masc_private_jsonl_dir_" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o700;
  let path = Filename.concat dir "keeper.jsonl" in
  Fun.protect
    ~finally:(fun () ->
      Sys.readdir dir
      |> Array.iter (fun name -> Sys.remove (Filename.concat dir name));
      Unix.rmdir dir)
    (fun () ->
      match
        Fs_compat.append_private_jsonl_durable_locked_result
          path
          "{\"row\":1}\n"
      with
      | Error error -> fail (Fs_compat.private_jsonl_append_error_to_string error)
      | Ok () ->
        check string "new durable JSONL content" "{\"row\":1}\n"
          (Fs_compat.load_file path);
        check int "new durable JSONL mode" 0o600
          ((Unix.stat path).Unix.st_perm land 0o777);
        check bool "separate cross-process lock inode exists" true
          (Sys.file_exists (path ^ ".lock")))
;;

let write_signal fd =
  let byte = Bytes.make 1 'x' in
  ignore (Unix.single_write fd byte 0 1 : int)
;;

let read_signal fd =
  let byte = Bytes.create 1 in
  match Unix.read fd byte 0 1 with
  | 1 -> ()
  | count -> failf "expected one synchronization byte, got %d" count
;;

let test_transcript_read_close_does_not_release_writer_lock () =
  with_temp_jsonl "{\"row\":0}\n" @@ fun path ->
  let ready_read, ready_write = Unix.pipe ~cloexec:true () in
  let release_read, release_write = Unix.pipe ~cloexec:true () in
  let holder_pid =
    match Unix.fork () with
    | 0 ->
      Unix.close ready_read;
      Unix.close release_write;
      let result =
        Fs_compat.update_private_file_durable_locked_result path (fun _existing ->
          write_signal ready_write;
          read_signal release_read;
          None, ())
      in
      (match result with Ok () -> exit 0 | Error _ -> exit 2)
    | pid -> pid
  in
  Unix.close ready_write;
  Unix.close release_read;
  read_signal ready_read;
  let read_fd = Unix.openfile path [ Unix.O_RDONLY; Unix.O_CLOEXEC ] 0 in
  Unix.close read_fd;
  let contender_fd =
    Unix.openfile (path ^ ".lock") [ Unix.O_RDWR; Unix.O_CLOEXEC ] 0
  in
  let try_lock () =
    ignore (Unix.lseek contender_fd 0 Unix.SEEK_SET : int);
    match Unix.lockf contender_fd Unix.F_TLOCK 0 with
    | () -> `Acquired
    | exception Unix.Unix_error ((Unix.EACCES | Unix.EAGAIN), _, _) ->
      `Contended
  in
  let before_release = try_lock () in
  (match before_release with
   | `Acquired -> Unix.lockf contender_fd Unix.F_ULOCK 0
   | `Contended -> ());
  write_signal release_write;
  Unix.close ready_read;
  Unix.close release_write;
  let _, holder_status = Unix.waitpid [] holder_pid in
  let after_release = try_lock () in
  (match after_release with
   | `Acquired -> Unix.lockf contender_fd Unix.F_ULOCK 0
   | `Contended -> ());
  Unix.close contender_fd;
  check bool "read-close does not release the writer lock" true
    (before_release = `Contended);
  check bool "contender acquires after writer release" true
    (after_release = `Acquired);
  check bool "holder exits cleanly" true (holder_status = Unix.WEXITED 0)
;;

let test_private_jsonl_append_preserves_complete_history () =
  with_temp_jsonl "{\"row\":1}\n" @@ fun path ->
  (match
     Fs_compat.append_private_jsonl_durable_locked_result
       path
       "{\"row\":2}\n{\"row\":3}\n"
   with
   | Ok () -> ()
   | Error error -> fail (Fs_compat.private_jsonl_append_error_to_string error));
  check string
    "complete rows appended"
    "{\"row\":1}\n{\"row\":2}\n{\"row\":3}\n"
    (Fs_compat.load_file path)
;;

let test_private_jsonl_append_rejects_incomplete_tail () =
  with_temp_jsonl "{\"row\":1}" @@ fun path ->
  (match
     Fs_compat.append_private_jsonl_durable_locked_result path "{\"row\":2}\n"
   with
   | Error Fs_compat.Incomplete_jsonl_tail -> ()
   | Error error -> fail (Fs_compat.private_jsonl_append_error_to_string error)
   | Ok () -> fail "append accepted an incomplete existing JSONL row");
  check string "incomplete bytes unchanged" "{\"row\":1}" (Fs_compat.load_file path)
;;

let test_private_jsonl_append_rejects_incomplete_suffix () =
  with_temp_jsonl "" @@ fun path ->
  match Fs_compat.append_private_jsonl_durable_locked_result path "{\"row\":1}" with
  | Error Fs_compat.Invalid_jsonl_suffix -> ()
  | Error error -> fail (Fs_compat.private_jsonl_append_error_to_string error)
  | Ok () -> fail "append accepted a non-terminated JSONL suffix"
;;

let () =
  run
    "fs_compat durable append"
    [ ( "durable_append"
      , [ test_case "success fsyncs" `Quick test_success_fsyncs
        ; test_case
            "partial ENOSPC rolls back and fsyncs"
            `Quick
            test_partial_enospc_rolls_back
        ; test_case
            "partial EIO rolls back and fsyncs"
            `Quick
            test_partial_eio_rolls_back
        ; test_case
            "append fsync failure rolls back and fsyncs"
            `Quick
            test_append_fsync_failure_rolls_back
        ; test_case
            "rollback truncate failure stays explicit"
            `Quick
            test_rollback_truncate_failure_is_explicit_and_still_fsyncs
        ; test_case
            "rollback fsync failure stays explicit"
            `Quick
            test_rollback_fsync_failure_is_explicit
        ; test_case
            "private JSONL append preserves complete history"
            `Quick
            test_private_jsonl_append_preserves_complete_history
        ; test_case
            "private JSONL first creation is durable"
            `Quick
            test_private_jsonl_first_creation_is_durable
        ; test_case
            "transcript reads preserve cross-process writer lock"
            `Quick
            test_transcript_read_close_does_not_release_writer_lock
        ; test_case
            "private JSONL append rejects incomplete tail"
            `Quick
            test_private_jsonl_append_rejects_incomplete_tail
        ; test_case
            "private JSONL append rejects incomplete suffix"
            `Quick
            test_private_jsonl_append_rejects_incomplete_suffix
        ] )
    ]
;;
