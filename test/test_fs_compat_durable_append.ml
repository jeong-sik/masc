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
  Fun.protect ~finally:(fun () -> Sys.remove path) (fun () -> f path)
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

let test_private_jsonl_append_returns_committed_end_offset () =
  let original = "{\"row\":1}\n" in
  let suffix = "{\"row\":2}\n{\"row\":3}\n" in
  with_temp_jsonl original @@ fun path ->
  (match
     Fs_compat.append_private_jsonl_durable_locked_with_end_offset_result
       path
       suffix
   with
   | Ok end_offset ->
     check int
       "committed newline-end byte offset"
       (String.length original + String.length suffix)
       end_offset
   | Error error -> fail (Fs_compat.private_jsonl_append_error_to_string error))
;;

let test_private_jsonl_append_at_exact_end_offset () =
  let original = "{\"row\":1}\n" in
  let suffix = "{\"row\":2}\n" in
  with_temp_jsonl original @@ fun path ->
  (match
     Fs_compat.append_private_jsonl_durable_locked_at_end_offset_result
       path
       ~expected_end_offset:(String.length original)
       suffix
   with
   | Ok end_offset ->
     check int
       "committed newline-end byte offset"
       (String.length original + String.length suffix)
       end_offset
   | Error error -> fail (Fs_compat.private_jsonl_append_error_to_string error));
  check string "exact append bytes" (original ^ suffix) (Fs_compat.load_file path)
;;

let test_private_jsonl_append_rejects_stale_end_offset () =
  let original = "{\"row\":1}\n" in
  with_temp_jsonl original @@ fun path ->
  (match
     Fs_compat.append_private_jsonl_durable_locked_at_end_offset_result
       path
       ~expected_end_offset:0
       "{\"row\":2}\n"
   with
   | Error
       (Fs_compat.End_offset_mismatch
          { expected = 0; actual }) ->
     check int "locked actual byte offset" (String.length original) actual
   | Error error -> fail (Fs_compat.private_jsonl_append_error_to_string error)
   | Ok _ -> fail "stale cursor unexpectedly appended");
  check string "stale append writes no bytes" original (Fs_compat.load_file path)
;;

let test_private_jsonl_slice_reads_exact_cursor_suffix () =
  let row1 = "{\"row\":1}\n" in
  let row2 = "{\"row\":2}\n" in
  let row3 = "{\"row\":3}\n" in
  with_temp_jsonl (row1 ^ row2 ^ row3) @@ fun path ->
  match
    Fs_compat.read_private_jsonl_slice_locked_result
      path
      ~from:(String.length row1)
  with
  | Ok slice ->
    check string "exact suffix" (row2 ^ row3) slice.bytes;
    check int
      "locked end offset"
      (String.length row1 + String.length row2 + String.length row3)
      slice.end_offset
  | Error _ -> fail "complete cursor slice was rejected"
;;

let test_private_jsonl_slice_rejects_invalid_cursors () =
  with_temp_jsonl "{\"row\":1}\n" @@ fun path ->
  (match Fs_compat.read_private_jsonl_slice_locked_result path ~from:(-1) with
   | Error (Fs_compat.Private_jsonl_slice.Negative_offset (-1)) -> ()
   | _ -> fail "negative cursor was not rejected");
  (match Fs_compat.read_private_jsonl_slice_locked_result path ~from:1 with
   | Error (Fs_compat.Private_jsonl_slice.Offset_not_at_row_boundary 1) -> ()
   | _ -> fail "mid-row cursor was not rejected");
  match Fs_compat.read_private_jsonl_slice_locked_result path ~from:1024 with
  | Error
      (Fs_compat.Private_jsonl_slice.Offset_beyond_end
        { offset = 1024; end_offset = 10 }) ->
    ()
  | _ -> fail "cursor beyond EOF was not rejected"
;;

let test_private_jsonl_slice_missing_store_contract () =
  let path = Filename.temp_file "masc_private_jsonl_missing_" ".jsonl" in
  Sys.remove path;
  (match Fs_compat.read_private_jsonl_slice_locked_result path ~from:0 with
   | Ok { bytes = ""; end_offset = 0 } -> ()
   | _ -> fail "missing origin was not treated as an empty stream");
  match Fs_compat.read_private_jsonl_slice_locked_result path ~from:1 with
  | Error (Fs_compat.Private_jsonl_slice.Missing_file_after_offset 1) -> ()
  | _ -> fail "missing non-origin cursor was not rejected"
;;

let test_private_jsonl_slice_rejects_incomplete_tail () =
  with_temp_jsonl "{\"row\":1}" @@ fun path ->
  match Fs_compat.read_private_jsonl_slice_locked_result path ~from:0 with
  | Error (Fs_compat.Private_jsonl_slice.Incomplete_tail 9) -> ()
  | _ -> fail "incomplete JSONL tail was not rejected"
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

let test_private_jsonl_append_respects_execution_context () =
  with_temp_jsonl "" @@ fun path ->
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Fun.protect
    ~finally:Fs_compat.clear_fs
    (fun () ->
       (match
          Fs_compat.append_private_jsonl_durable_locked_result path "{\"fiber\":1}\n"
        with
        | Ok () -> ()
        | Error error -> fail (Fs_compat.private_jsonl_append_error_to_string error));
       let raw_domain_result =
         Domain.spawn (fun () ->
           Fs_compat.append_private_jsonl_durable_locked_result path "{\"domain\":2}\n")
         |> Domain.join
       in
       (match raw_domain_result with
        | Ok () -> ()
        | Error error -> fail (Fs_compat.private_jsonl_append_error_to_string error));
       check string
         "Eio fiber and raw Domain append once"
         "{\"fiber\":1}\n{\"domain\":2}\n"
         (Fs_compat.load_file path))
;;

let remove_if_present path =
  match Unix.unlink path with
  | () -> ()
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
;;

let with_transaction_jsonl initial f =
  let path = Filename.temp_file "masc_private_jsonl_transaction_" ".jsonl" in
  (match initial with
   | Some content ->
     let output = open_out_bin path in
     output_string output content;
     close_out output
   | None -> remove_if_present path);
  Fun.protect
    ~finally:(fun () ->
      remove_if_present path;
      remove_if_present (Fs_compat.private_jsonl_lock_path path))
    (fun () -> f path)
;;

let transaction_snapshot path ~after =
  match Fs_compat.read_private_jsonl_durable_locked_result path ~after with
  | Ok snapshot -> snapshot
  | Error error -> fail (Fs_compat.private_jsonl_transaction_error_to_string error)
;;

let transaction_snapshot_with_io ~io path ~after =
  match
    Fs_compat.read_private_jsonl_durable_locked_with_io_for_testing
      ~io
      path
      ~after
  with
  | Ok snapshot -> snapshot
  | Error error -> fail (Fs_compat.private_jsonl_transaction_error_to_string error)
;;

let write_stable_lock_fixture path contents permissions =
  let lock_path = Fs_compat.private_jsonl_lock_path path in
  let output = open_out_bin lock_path in
  output_string output contents;
  close_out output;
  Unix.chmod lock_path permissions
;;

let transaction_append path ~expected suffix =
  match
    Fs_compat.append_private_jsonl_durable_locked_at_cursor_result
      path
      ~expected
      suffix
  with
  | Ok cursor -> cursor
  | Error error -> fail (Fs_compat.private_jsonl_transaction_error_to_string error)
;;

let injected_close_io ~fail_calls =
  let calls = ref 0 in
  let io : Fs_compat.private_jsonl_transaction_io_for_testing =
    { before_sync_parent = (fun _dir -> ())
    ; close_fd =
        (fun fd ->
          incr calls;
          Unix.close fd;
          if List.mem !calls fail_calls
          then
            raise
              (Unix.Unix_error
                 (Unix.EIO, "injected_private_jsonl_close", string_of_int !calls)))
    }
  in
  io, calls
;;

let check_transaction_close_failure
      ~label
      ~operation
      (failure : Fs_compat.private_jsonl_operation_failure)
  =
  check bool (label ^ " operation") true (failure.operation = operation);
  match failure.exception_ with
  | Unix.Unix_error (Unix.EIO, "injected_private_jsonl_close", _) -> ()
  | exception_ ->
    fail
      (Printf.sprintf
         "%s lost injected close failure: %s"
         label
         (Printexc.to_string exception_))
;;

let test_private_jsonl_transaction_preserves_primary_when_data_close_fails () =
  with_transaction_jsonl (Some "incomplete") @@ fun path ->
  let io, calls = injected_close_io ~fail_calls:[ 1 ] in
  (match
     Fs_compat.read_private_jsonl_durable_locked_with_io_for_testing
       ~io
       path
       ~after:None
   with
   | Error
       (Fs_compat.Transaction_settlement_failed
         { primary =
             Fs_compat.Transaction_failed
               (Fs_compat.Incomplete_transaction_tail _)
         ; cleanup_failures = [ cleanup_failure ]
         }) ->
     check_transaction_close_failure
       ~label:"data descriptor cleanup"
       ~operation:Fs_compat.Close_transaction_data
       cleanup_failure
   | Error error -> fail (Fs_compat.private_jsonl_transaction_error_to_string error)
   | Ok _ -> fail "data close failure was silently accepted");
  check int "data and stable lock descriptors closed" 2 !calls
;;

let test_private_jsonl_transaction_accumulates_nested_close_failures () =
  with_transaction_jsonl (Some "{\"row\":1}\n") @@ fun path ->
  let io, calls = injected_close_io ~fail_calls:[ 1; 2 ] in
  (match
     Fs_compat.read_private_jsonl_durable_locked_with_io_for_testing
       ~io
       path
       ~after:None
   with
   | Error
       (Fs_compat.Transaction_settlement_failed
         { primary =
             Fs_compat.Transaction_succeeded
               (Fs_compat.Snapshot_succeeded snapshot)
         ; cleanup_failures = [ data_failure; lock_failure ]
         }) ->
     check string "successful snapshot receipt" "{\"row\":1}\n" snapshot.bytes;
     check_transaction_close_failure
       ~label:"data descriptor cleanup"
       ~operation:Fs_compat.Close_transaction_data
       data_failure;
     check_transaction_close_failure
       ~label:"stable lock descriptor cleanup"
       ~operation:Fs_compat.Close_stable_lock
       lock_failure
   | Error error -> fail (Fs_compat.private_jsonl_transaction_error_to_string error)
   | Ok _ -> fail "nested close failures were silently accepted");
  check int "both nested descriptors closed" 2 !calls
;;

exception Requested_private_jsonl_cancellation

type private_jsonl_append_cancellation_outcome =
  | Append_returned of
      ( Fs_compat.Private_jsonl_cursor.t
        , Fs_compat.private_jsonl_transaction_error )
        result
  | Append_cancelled

type private_jsonl_close_barrier =
  { entered : unit Eio.Promise.t
  ; resolve_entered : unit Eio.Promise.u
  ; first_close : bool Atomic.t
  ; close_calls : int Atomic.t
  ; mutex : Stdlib.Mutex.t
  ; condition : Stdlib.Condition.t
  ; mutable released : bool
  }

let private_jsonl_close_barrier () =
  let entered, resolve_entered = Eio.Promise.create () in
  { entered
  ; resolve_entered
  ; first_close = Atomic.make true
  ; close_calls = Atomic.make 0
  ; mutex = Stdlib.Mutex.create ()
  ; condition = Stdlib.Condition.create ()
  ; released = false
  }
;;

let release_private_jsonl_close barrier =
  Stdlib.Mutex.protect barrier.mutex (fun () ->
    if not barrier.released
    then (
      barrier.released <- true;
      Stdlib.Condition.broadcast barrier.condition))
;;

let private_jsonl_blocking_close_io barrier =
  let io : Fs_compat.private_jsonl_transaction_io_for_testing =
    { before_sync_parent = (fun _dir -> ())
    ; close_fd =
        (fun fd ->
          ignore (Atomic.fetch_and_add barrier.close_calls 1 : int);
          if Atomic.compare_and_set barrier.first_close true false
          then (
            Eio.Promise.resolve barrier.resolve_entered ();
            Stdlib.Mutex.protect barrier.mutex (fun () ->
              while not barrier.released do
                Stdlib.Condition.wait barrier.condition barrier.mutex
              done));
          Unix.close fd)
    }
  in
  io
;;

let test_private_jsonl_append_cancellation_settles_once_with_receipt () =
  with_transaction_jsonl (Some "{\"row\":1}\n") @@ fun path ->
  Eio_main.run @@ fun _env ->
  let origin = transaction_snapshot path ~after:None in
  let barrier = private_jsonl_close_barrier () in
  let context, resolve_context = Eio.Promise.create () in
  let outcome, resolve_outcome = Eio.Promise.create () in
  Fun.protect
    ~finally:(fun () -> release_private_jsonl_close barrier)
    (fun () ->
       Eio.Switch.run @@ fun sw ->
       Eio.Fiber.fork ~sw (fun () ->
         let outcome =
           try
             Eio.Cancel.sub @@ fun context ->
             Eio.Promise.resolve resolve_context context;
             Append_returned
               (Fs_compat.append_private_jsonl_durable_locked_at_cursor_with_io_for_testing
                  ~io:(private_jsonl_blocking_close_io barrier)
                  path
                  ~expected:origin.cursor
                  "{\"row\":2}\n")
           with
           | Eio.Cancel.Cancelled _ -> Append_cancelled
         in
         Eio.Promise.resolve resolve_outcome outcome);
       let context = Eio.Promise.await context in
       Eio.Promise.await barrier.entered;
       Eio.Cancel.cancel context Requested_private_jsonl_cancellation;
       release_private_jsonl_close barrier;
       match Eio.Promise.await outcome with
       | Append_cancelled ->
         fail "committed append lost its terminal receipt to cancellation"
       | Append_returned (Error error) ->
         fail (Fs_compat.private_jsonl_transaction_error_to_string error)
       | Append_returned (Ok committed) ->
         check bool
           "cancellation path returns committed cursor"
           false
           (Fs_compat.Private_jsonl_cursor.equal origin.cursor committed));
  check int "cancellation path closes both descriptors" 2 (Atomic.get barrier.close_calls);
  check string
    "cancellation path commits suffix exactly once"
    "{\"row\":1}\n{\"row\":2}\n"
    (Fs_compat.load_file path)
;;

let test_private_jsonl_transaction_missing_and_delta_contract () =
  with_transaction_jsonl None @@ fun path ->
  let origin = transaction_snapshot path ~after:None in
  let committed = transaction_append path ~expected:origin.cursor "{\"row\":1}\n" in
  let delta = transaction_snapshot path ~after:(Some committed) in
  check string "no bytes after committed cursor" "" delta.bytes;
  let next = transaction_append path ~expected:committed "{\"row\":2}\n" in
  let delta = transaction_snapshot path ~after:(Some committed) in
  check string "exact appended delta" "{\"row\":2}\n" delta.bytes;
  check bool
    "delta advances durable cursor"
    true
    (Fs_compat.Private_jsonl_cursor.equal next delta.cursor)
;;

let test_private_jsonl_transaction_rejects_second_writer_cursor () =
  with_transaction_jsonl (Some "{\"row\":1}\n") @@ fun path ->
  let snapshot = transaction_snapshot path ~after:None in
  ignore (transaction_append path ~expected:snapshot.cursor "{\"winner\":1}\n");
  (match
     Fs_compat.append_private_jsonl_durable_locked_at_cursor_result
       path
       ~expected:snapshot.cursor
       "{\"loser\":1}\n"
   with
   | Error (Fs_compat.Cursor_mismatch _) -> ()
   | Error error -> fail (Fs_compat.private_jsonl_transaction_error_to_string error)
   | Ok _ -> fail "second writer committed from a stale cursor");
  check string
    "stale writer writes zero bytes"
    "{\"row\":1}\n{\"winner\":1}\n"
    (Fs_compat.load_file path)
;;

let test_private_jsonl_transaction_rejects_same_length_rewrite_aba () =
  let before = "{\"row\":1}\n" in
  let after = "{\"row\":2}\n" in
  check int "fixture lengths match" (String.length before) (String.length after);
  with_transaction_jsonl (Some before) @@ fun path ->
  let snapshot = transaction_snapshot path ~after:None in
  let rewritten =
    match
      Fs_compat.rewrite_private_jsonl_durable_locked_at_cursor_result
        path
        ~expected:snapshot.cursor
        after
    with
    | Ok cursor -> cursor
    | Error error -> fail (Fs_compat.private_jsonl_transaction_error_to_string error)
  in
  check bool
    "same-length rewrite changes durable identity"
    false
    (Fs_compat.Private_jsonl_cursor.equal snapshot.cursor rewritten);
  (match
     Fs_compat.append_private_jsonl_durable_locked_at_cursor_result
       path
       ~expected:snapshot.cursor
       "{\"stale\":1}\n"
   with
   | Error (Fs_compat.Cursor_mismatch _) -> ()
   | Error error -> fail (Fs_compat.private_jsonl_transaction_error_to_string error)
   | Ok _ -> fail "stale pre-rewrite cursor passed a same-length ABA");
  check string "rewrite remains authoritative" after (Fs_compat.load_file path)
;;

let test_private_jsonl_transaction_lock_is_private () =
  with_transaction_jsonl None @@ fun path ->
  ignore (transaction_snapshot path ~after:None);
  let permissions =
    (Unix.stat (Fs_compat.private_jsonl_lock_path path)).Unix.st_perm land 0o777
  in
  check int "stable lock permissions" 0o600 permissions
;;

let test_private_jsonl_stable_lock_parent_sync_is_one_shot () =
  with_transaction_jsonl (Some "{\"row\":1}\n") @@ fun path ->
  let parent_syncs = ref 0 in
  let io : Fs_compat.private_jsonl_transaction_io_for_testing =
    { before_sync_parent = (fun _dir -> incr parent_syncs)
    ; close_fd = Unix.close
    }
  in
  let snapshot = transaction_snapshot_with_io ~io path ~after:None in
  ignore (transaction_snapshot_with_io ~io path ~after:(Some snapshot.cursor));
  ignore (transaction_snapshot_with_io ~io path ~after:(Some snapshot.cursor));
  check int "stable lock parent sync count" 1 !parent_syncs
;;

let test_private_jsonl_stable_lock_parent_sync_failure_retries () =
  with_transaction_jsonl (Some "{\"row\":1}\n") @@ fun path ->
  let io : Fs_compat.private_jsonl_transaction_io_for_testing =
    { before_sync_parent =
        (fun dir ->
          raise (Unix.Unix_error (Unix.EIO, "injected_parent_fsync", dir)))
    ; close_fd = Unix.close
    }
  in
  (match
     Fs_compat.read_private_jsonl_durable_locked_with_io_for_testing
       ~io
       path
       ~after:None
   with
   | Error
       (Fs_compat.Private_jsonl_operation_failed
         { operation = Fs_compat.Sync_stable_lock_parent; _ }) ->
     ()
   | Error error -> fail (Fs_compat.private_jsonl_transaction_error_to_string error)
   | Ok _ -> fail "stable lock parent-sync failure was silently accepted");
  let lock_path = Fs_compat.private_jsonl_lock_path path in
  check string "failed initialization remains preparing" "" (Fs_compat.load_file lock_path);
  ignore (transaction_snapshot path ~after:None);
  check bool
    "successful retry publishes ready state"
    true
    (String.length (Fs_compat.load_file lock_path) > 0)
;;

let test_private_jsonl_stable_lock_invalid_state_fails_closed () =
  with_transaction_jsonl (Some "{\"row\":1}\n") @@ fun path ->
  let invalid = "invalid-ready-state" in
  write_stable_lock_fixture path invalid 0o600;
  match Fs_compat.read_private_jsonl_durable_locked_result path ~after:None with
  | Error (Fs_compat.Invalid_stable_lock_state { observed_length; _ }) ->
    check int "invalid stable lock length" (String.length invalid) observed_length
  | Error error -> fail (Fs_compat.private_jsonl_transaction_error_to_string error)
  | Ok _ -> fail "invalid stable lock state was accepted"
;;

let test_private_jsonl_stable_lock_permission_drift_fails_closed () =
  with_transaction_jsonl (Some "{\"row\":1}\n") @@ fun path ->
  write_stable_lock_fixture path "" 0o640;
  let lock_path = Fs_compat.private_jsonl_lock_path path in
  (match Fs_compat.read_private_jsonl_durable_locked_result path ~after:None with
   | Error (Fs_compat.Unexpected_stable_lock_permissions { actual; _ }) ->
     check int "observed stable lock permissions" 0o640 actual
   | Error error -> fail (Fs_compat.private_jsonl_transaction_error_to_string error)
   | Ok _ -> fail "stable lock permission drift was silently repaired");
  check int
    "permission drift remains untouched"
    0o640
    ((Unix.stat lock_path).Unix.st_perm land 0o7777)
;;

let test_private_jsonl_transaction_rejects_data_aliases () =
  with_transaction_jsonl (Some "{\"row\":1}\n") @@ fun path ->
  let hardlink = path ^ ".hardlink" in
  Fun.protect
    ~finally:(fun () -> remove_if_present hardlink)
    (fun () ->
       Unix.link path hardlink;
       match Fs_compat.read_private_jsonl_durable_locked_result path ~after:None with
       | Error (Fs_compat.Ambiguous_transaction_file_identity { link_count; _ }) ->
         check int "hard-link count" 2 link_count
       | Error error -> fail (Fs_compat.private_jsonl_transaction_error_to_string error)
       | Ok _ -> fail "hard-linked transaction data was accepted")
;;

let test_private_jsonl_transaction_rejects_symlink_lock_without_chmod () =
  with_transaction_jsonl None @@ fun path ->
  let lock_path = Fs_compat.private_jsonl_lock_path path in
  let external_path =
    Filename.temp_file "masc_private_jsonl_external_lock_" ".lock"
  in
  Fun.protect
    ~finally:(fun () -> remove_if_present external_path)
    (fun () ->
       Unix.chmod external_path 0o644;
       Unix.symlink external_path lock_path;
       (match Fs_compat.read_private_jsonl_durable_locked_result path ~after:None with
        | Error (Fs_compat.Unexpected_transaction_file_kind Unix.S_LNK) -> ()
        | Error error ->
          fail (Fs_compat.private_jsonl_transaction_error_to_string error)
        | Ok _ -> fail "symbolic-link stable lock was accepted");
       let permissions = (Unix.stat external_path).Unix.st_perm land 0o777 in
       check int "external target permissions unchanged" 0o644 permissions)
;;

let test_private_jsonl_transaction_lock_contention_is_typed () =
  with_transaction_jsonl None @@ fun path ->
  ignore (transaction_snapshot path ~after:None);
  let ready_read, ready_write = Unix.pipe ~cloexec:true () in
  let release_read, release_write = Unix.pipe ~cloexec:true () in
  match Unix.fork () with
  | 0 ->
    Unix.close ready_read;
    Unix.close release_write;
    (try
       let lock_fd =
         Unix.openfile
           (Fs_compat.private_jsonl_lock_path path)
           [ Unix.O_RDWR; Unix.O_CLOEXEC ]
           0
       in
       Unix.lockf lock_fd Unix.F_LOCK 0;
       ignore (Unix.write_substring ready_write "x" 0 1 : int);
       let release = Bytes.create 1 in
       ignore (Unix.read release_read release 0 1 : int);
       Unix.close lock_fd;
       Unix._exit 0
     with _ -> Unix._exit 2)
  | child ->
    Unix.close ready_write;
    Unix.close release_read;
    let ready = Bytes.create 1 in
    ignore (Unix.read ready_read ready 0 1 : int);
    Fun.protect
      ~finally:(fun () ->
        ignore (Unix.write_substring release_write "x" 0 1 : int);
        Unix.close ready_read;
        Unix.close release_write;
        match Unix.waitpid [] child with
        | _, Unix.WEXITED 0 -> ()
        | _, status ->
          fail
            (Printf.sprintf
               "stable-lock child failed: %s"
               (match status with
                | Unix.WEXITED code -> Printf.sprintf "exit %d" code
                | Unix.WSIGNALED signal -> Printf.sprintf "signal %d" signal
                | Unix.WSTOPPED signal -> Printf.sprintf "stopped %d" signal)))
      (fun () ->
         match Fs_compat.read_private_jsonl_durable_locked_result path ~after:None with
         | Error (Fs_compat.Stable_lock_contended _) -> ()
         | Error error ->
           fail (Fs_compat.private_jsonl_transaction_error_to_string error)
         | Ok _ -> fail "cross-process stable-lock contention was accepted")
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
            "private JSONL append returns committed end offset"
            `Quick
            test_private_jsonl_append_returns_committed_end_offset
        ; test_case
            "private JSONL append accepts exact end offset"
            `Quick
            test_private_jsonl_append_at_exact_end_offset
        ; test_case
            "private JSONL append rejects stale end offset"
            `Quick
            test_private_jsonl_append_rejects_stale_end_offset
        ; test_case
            "private JSONL cursor read returns exact suffix"
            `Quick
            test_private_jsonl_slice_reads_exact_cursor_suffix
        ; test_case
            "private JSONL cursor read rejects invalid cursors"
            `Quick
            test_private_jsonl_slice_rejects_invalid_cursors
        ; test_case
            "private JSONL cursor read handles missing stores"
            `Quick
            test_private_jsonl_slice_missing_store_contract
        ; test_case
            "private JSONL cursor read rejects incomplete tail"
            `Quick
            test_private_jsonl_slice_rejects_incomplete_tail
        ; test_case
            "private JSONL append rejects incomplete tail"
            `Quick
            test_private_jsonl_append_rejects_incomplete_tail
        ; test_case
            "private JSONL append rejects incomplete suffix"
            `Quick
            test_private_jsonl_append_rejects_incomplete_suffix
        ; test_case
            "private JSONL stable lock contention is typed"
            `Quick
            test_private_jsonl_transaction_lock_contention_is_typed
        ; test_case
            "private JSONL append respects execution context"
            `Quick
            test_private_jsonl_append_respects_execution_context
        ; test_case
            "private JSONL transaction handles missing stores and deltas"
            `Quick
            test_private_jsonl_transaction_missing_and_delta_contract
        ; test_case
            "private JSONL transaction rejects a second writer cursor"
            `Quick
            test_private_jsonl_transaction_rejects_second_writer_cursor
        ; test_case
            "private JSONL transaction rejects same-length rewrite ABA"
            `Quick
            test_private_jsonl_transaction_rejects_same_length_rewrite_aba
        ; test_case
            "private JSONL stable lock is private"
            `Quick
            test_private_jsonl_transaction_lock_is_private
        ; test_case
            "private JSONL stable lock parent sync is one-shot"
            `Quick
            test_private_jsonl_stable_lock_parent_sync_is_one_shot
        ; test_case
            "private JSONL stable lock retries failed parent sync"
            `Quick
            test_private_jsonl_stable_lock_parent_sync_failure_retries
        ; test_case
            "private JSONL stable lock invalid state fails closed"
            `Quick
            test_private_jsonl_stable_lock_invalid_state_fails_closed
        ; test_case
            "private JSONL stable lock permission drift fails closed"
            `Quick
            test_private_jsonl_stable_lock_permission_drift_fails_closed
        ; test_case
            "private JSONL transaction rejects data aliases"
            `Quick
            test_private_jsonl_transaction_rejects_data_aliases
        ; test_case
            "private JSONL stable lock rejects symlink aliases"
            `Quick
            test_private_jsonl_transaction_rejects_symlink_lock_without_chmod
        ; test_case
            "private JSONL data close preserves primary error"
            `Quick
            test_private_jsonl_transaction_preserves_primary_when_data_close_fails
        ; test_case
            "private JSONL nested close failures accumulate"
            `Quick
            test_private_jsonl_transaction_accumulates_nested_close_failures
        ; test_case
            "private JSONL append cancellation settles once with receipt"
            `Quick
            test_private_jsonl_append_cancellation_settles_once_with_receipt
        ] )
    ]
;;
