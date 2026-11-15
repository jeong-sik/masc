open Fs_compat_base_io
open Fs_compat_owned_file
open Fs_compat_durable_append

let run_blocking_private_file_transaction ~label ~path:_ f =
  match execution_context () with
  | Non_eio -> f ()
  | Eio_fiber -> Fs_compat_internal.Systhread_host.run ~label f
;;

module Private_jsonl_cursor = struct
  type t =
    | Missing
    | Present of
        { device : int
        ; inode : int
        ; end_offset : int
        }

  let equal left right =
    match left, right with
    | Missing, Missing -> true
    | ( Present
          { device = left_device
          ; inode = left_inode
          ; end_offset = left_end_offset
          }
      , Present
          { device = right_device
          ; inode = right_inode
          ; end_offset = right_end_offset
          } ) ->
      Int.equal left_device right_device
      && Int.equal left_inode right_inode
      && Int.equal left_end_offset right_end_offset
    | Missing, Present _ | Present _, Missing -> false
  ;;

  let is_missing = function Missing -> true | Present _ -> false

  let to_string = function
    | Missing -> "missing"
    | Present { device; inode; end_offset } ->
      Printf.sprintf
        "present(device=%d,inode=%d,end_offset=%d)"
        device
        inode
        end_offset
  ;;

  let fingerprint cursor = Agent_core_sha256.(digest_string (to_string cursor) |> to_hex)

  let prefix_end_offset cursor ~device ~inode ~file_length =
    match cursor with
    | Missing -> None
    | Present
        { device = expected_device
        ; inode = expected_inode
        ; end_offset
        } ->
      if Int.equal expected_device device
         && Int.equal expected_inode inode
         && end_offset <= file_length
      then Some end_offset
      else None
  ;;
end

type private_jsonl_snapshot =
  { bytes : string
  ; cursor : Private_jsonl_cursor.t
  }

type private_jsonl_transaction_operation =
  | Create_parent_directory
  | Canonicalize_parent_directory
  | Inspect_stable_lock
  | Open_stable_lock
  | Set_stable_lock_permissions
  | Sync_stable_lock_parent
  | Acquire_stable_lock
  | Read_stable_lock_state
  | Write_stable_lock_state
  | Sync_stable_lock
  | Close_stable_lock
  | Open_transaction_data
  | Set_transaction_data_permissions
  | Inspect_transaction_data
  | Inspect_transaction_path
  | Read_transaction_data
  | Close_transaction_data
  | Create_rewrite_stage
  | Set_rewrite_stage_permissions
  | Write_rewrite_stage
  | Sync_rewrite_stage
  | Close_rewrite_stage
  | Rename_rewrite_stage
  | Sync_rewrite_parent
  | Inspect_rewritten_data
  | Remove_rewrite_stage
  | Truncate_transaction_data
  | Sync_transaction_data
  | Remove_transaction_data
  | Sync_removal_parent

type private_jsonl_operation_failure =
  { operation : private_jsonl_transaction_operation
  ; exception_ : exn
  ; backtrace : Printexc.raw_backtrace
  }

type ('value, 'error) private_file_transaction_outcome =
  | Private_file_succeeded of 'value
  | Private_file_succeeded_with_cleanup_failure of
      { value : 'value
      ; cleanup_failure : private_jsonl_operation_failure
      }
  | Private_file_failed of 'error
  | Private_file_failed_with_cleanup_failure of
      { error : 'error
      ; cleanup_failure : private_jsonl_operation_failure
      }

type private_jsonl_transaction_success =
  | Snapshot_succeeded of private_jsonl_snapshot
  | Cursor_succeeded of Private_jsonl_cursor.t
  | Cursor_precondition_succeeded of Private_jsonl_cursor.t

type private_jsonl_transaction_primary =
  | Transaction_succeeded of private_jsonl_transaction_success
  | Transaction_failed of private_jsonl_transaction_error

and private_jsonl_transaction_error =
  | Stable_lock_contended of { lock_path : string }
  | Unexpected_stable_lock_permissions of
      { path : string
      ; actual : int
      }
  | Invalid_stable_lock_state of
      { path : string
      ; observed_length : int
      }
  | Cursor_mismatch of
      { expected : Private_jsonl_cursor.t
      ; actual : Private_jsonl_cursor.t
      }
  | Unexpected_transaction_file_kind of Unix.file_kind
  | Ambiguous_transaction_file_identity of
      { path : string
      ; link_count : int
      }
  | Transaction_path_binding_changed of { path : string }
  | Transaction_content_changed of { path : string }
  | Incomplete_transaction_tail of { end_offset : int }
  | Invalid_transaction_suffix
  | Private_jsonl_operation_failed of private_jsonl_operation_failure
  | Rewrite_stage_failed of
      { failure : private_jsonl_operation_failure
      ; cleanup_failures : private_jsonl_operation_failure list
      }
  | Rewrite_published_durability_unknown of
      { cursor : Private_jsonl_cursor.t option
      ; failure : private_jsonl_operation_failure
      }
  | Transaction_settlement_failed of
      { primary : private_jsonl_transaction_primary
      ; cleanup_failures : private_jsonl_operation_failure list
      }
  | Transaction_append_failed of durable_append_error

type 'a private_jsonl_success_receipt =
  { value : 'a
  ; settlement_error : private_jsonl_transaction_error option
  }

let private_jsonl_settlement_success = function
  | (Transaction_settlement_failed
      { primary = Transaction_succeeded success; _ } as error) ->
    Some (success, error)
  | Transaction_settlement_failed { primary = Transaction_failed _; _ }
  | Stable_lock_contended _
  | Unexpected_stable_lock_permissions _
  | Invalid_stable_lock_state _
  | Cursor_mismatch _
  | Unexpected_transaction_file_kind _
  | Ambiguous_transaction_file_identity _
  | Transaction_path_binding_changed _
  | Transaction_content_changed _
  | Incomplete_transaction_tail _
  | Invalid_transaction_suffix
  | Private_jsonl_operation_failed _
  | Rewrite_stage_failed _
  | Rewrite_published_durability_unknown _
  | Transaction_append_failed _ -> None
;;

let private_jsonl_snapshot_success_receipt = function
  | Ok value -> Ok { value; settlement_error = None }
  | Error error ->
    (match private_jsonl_settlement_success error with
     | Some (Snapshot_succeeded value, settlement_error) ->
       Ok { value; settlement_error = Some settlement_error }
     | Some
         ( (Cursor_succeeded _ | Cursor_precondition_succeeded _)
         , _ )
     | None -> Error error)
;;

let private_jsonl_cursor_success_receipt = function
  | Ok value -> Ok { value; settlement_error = None }
  | Error error ->
    (match private_jsonl_settlement_success error with
     | Some (Cursor_succeeded value, settlement_error) ->
       Ok { value; settlement_error = Some settlement_error }
     | Some
         ( (Snapshot_succeeded _ | Cursor_precondition_succeeded _)
         , _ )
     | None -> Error error)
;;

let private_jsonl_operation_to_string = function
  | Create_parent_directory -> "create parent directory"
  | Canonicalize_parent_directory -> "canonicalize parent directory"
  | Inspect_stable_lock -> "inspect stable lock"
  | Open_stable_lock -> "open stable lock"
  | Set_stable_lock_permissions -> "set stable lock permissions"
  | Sync_stable_lock_parent -> "sync stable lock parent"
  | Acquire_stable_lock -> "acquire stable lock"
  | Read_stable_lock_state -> "read stable lock state"
  | Write_stable_lock_state -> "write stable lock state"
  | Sync_stable_lock -> "sync stable lock"
  | Close_stable_lock -> "close stable lock"
  | Open_transaction_data -> "open transaction data"
  | Set_transaction_data_permissions -> "set transaction data permissions"
  | Inspect_transaction_data -> "inspect transaction data"
  | Inspect_transaction_path -> "inspect transaction path"
  | Read_transaction_data -> "read transaction data"
  | Close_transaction_data -> "close transaction data"
  | Create_rewrite_stage -> "create rewrite stage"
  | Set_rewrite_stage_permissions -> "set rewrite stage permissions"
  | Write_rewrite_stage -> "write rewrite stage"
  | Sync_rewrite_stage -> "sync rewrite stage"
  | Close_rewrite_stage -> "close rewrite stage"
  | Rename_rewrite_stage -> "rename rewrite stage"
  | Sync_rewrite_parent -> "sync rewrite parent"
  | Inspect_rewritten_data -> "inspect rewritten data"
  | Remove_rewrite_stage -> "remove rewrite stage"
  | Truncate_transaction_data -> "truncate transaction data"
  | Sync_transaction_data -> "sync transaction data"
  | Remove_transaction_data -> "remove transaction data"
  | Sync_removal_parent -> "sync removal parent"
;;

let private_jsonl_operation_failure_to_string failure =
  Printf.sprintf
    "%s failed: %s"
    (private_jsonl_operation_to_string failure.operation)
    (Printexc.to_string failure.exception_)
;;

let private_jsonl_cleanup_failures_to_string cleanup_failures =
  cleanup_failures
  |> List.map private_jsonl_operation_failure_to_string
  |> String.concat "; "
;;

let rec private_jsonl_transaction_error_to_string = function
  | Stable_lock_contended { lock_path } ->
    Printf.sprintf "private JSONL stable lock is contended: %s" lock_path
  | Unexpected_stable_lock_permissions { path; actual } ->
    Printf.sprintf
      "private JSONL stable lock permissions are %04o, expected 0600: %s"
      actual
      path
  | Invalid_stable_lock_state { path; observed_length } ->
    Printf.sprintf
      "private JSONL stable lock has invalid durable state: %s (%d bytes)"
      path
      observed_length
  | Cursor_mismatch { expected; actual } ->
    Printf.sprintf
      "private JSONL cursor mismatch: expected %s, observed %s"
      (Private_jsonl_cursor.to_string expected)
      (Private_jsonl_cursor.to_string actual)
  | Unexpected_transaction_file_kind kind ->
    Printf.sprintf
      "private JSONL transaction target has unexpected file kind: %s"
      (file_kind_to_string kind)
  | Ambiguous_transaction_file_identity { path; link_count } ->
    Printf.sprintf
      "private JSONL transaction path has ambiguous hard-link identity: %s (links=%d)"
      path
      link_count
  | Transaction_path_binding_changed { path } ->
    Printf.sprintf
      "private JSONL transaction path binding changed during operation: %s"
      path
  | Transaction_content_changed { path } ->
    Printf.sprintf "private JSONL transaction content changed since its snapshot: %s" path
  | Incomplete_transaction_tail { end_offset } ->
    Printf.sprintf
      "private JSONL transaction target has an incomplete tail at end %d"
      end_offset
  | Invalid_transaction_suffix ->
    "private JSONL transaction payload must be empty or newline-terminated"
  | Private_jsonl_operation_failed failure ->
    private_jsonl_operation_failure_to_string failure
  | Rewrite_stage_failed { failure; cleanup_failures } ->
    let cleanup =
      match cleanup_failures with
      | [] -> ""
      | cleanup_failures ->
        Printf.sprintf
          "; cleanup also failed: %s"
          (private_jsonl_cleanup_failures_to_string cleanup_failures)
    in
    private_jsonl_operation_failure_to_string failure ^ cleanup
  | Rewrite_published_durability_unknown { cursor; failure } ->
    Printf.sprintf
      "private JSONL rewrite was published but durability is unknown (cursor=%s): %s"
      (match cursor with
       | None -> "unknown"
       | Some cursor -> Private_jsonl_cursor.to_string cursor)
      (private_jsonl_operation_failure_to_string failure)
  | Transaction_settlement_failed { primary; cleanup_failures } ->
    let primary =
      match primary with
      | Transaction_succeeded (Snapshot_succeeded snapshot) ->
        Printf.sprintf
          "private JSONL snapshot read succeeded (cursor=%s)"
          (Private_jsonl_cursor.to_string snapshot.cursor)
      | Transaction_succeeded (Cursor_succeeded cursor) ->
        Printf.sprintf
          "private JSONL cursor operation succeeded (cursor=%s)"
          (Private_jsonl_cursor.to_string cursor)
      | Transaction_succeeded (Cursor_precondition_succeeded cursor) ->
        Printf.sprintf
          "private JSONL cursor precondition read succeeded (cursor=%s)"
          (Private_jsonl_cursor.to_string cursor)
      | Transaction_failed primary ->
        private_jsonl_transaction_error_to_string primary
    in
    Printf.sprintf
      "%s; descriptor settlement failed: %s"
      primary
      (private_jsonl_cleanup_failures_to_string cleanup_failures)
  | Transaction_append_failed append_error ->
    durable_append_error_to_string append_error
;;

(* [wrapped] is true once one [Transaction_settlement_failed] has been
   entered. A settlement failure nested inside another one is not followed. *)
let rec private_jsonl_transaction_error_is_incomplete_tail_at ~wrapped = function
  | Incomplete_transaction_tail _ -> true
  | Transaction_settlement_failed { primary = Transaction_failed inner; _ } ->
    (not wrapped)
    && private_jsonl_transaction_error_is_incomplete_tail_at ~wrapped:true inner
  | Transaction_settlement_failed { primary = Transaction_succeeded _; _ } -> false
  | Stable_lock_contended _
  | Unexpected_stable_lock_permissions _
  | Invalid_stable_lock_state _
  | Cursor_mismatch _
  | Transaction_content_changed _
  | Unexpected_transaction_file_kind _
  | Ambiguous_transaction_file_identity _
  | Transaction_path_binding_changed _
  | Invalid_transaction_suffix
  | Private_jsonl_operation_failed _
  | Rewrite_stage_failed _
  | Rewrite_published_durability_unknown _
  | Transaction_append_failed _ -> false
;;

let private_jsonl_transaction_error_is_incomplete_tail =
  private_jsonl_transaction_error_is_incomplete_tail_at ~wrapped:false
;;

let private_jsonl_failure operation exception_ =
  { operation; exception_; backtrace = Printexc.get_raw_backtrace () }
;;

let private_jsonl_capture operation f =
  match f () with
  | value -> Ok value
  | exception (Eio.Cancel.Cancelled _ as cancellation) -> raise cancellation
  | exception exception_ -> Error (private_jsonl_failure operation exception_)
;;

let private_file_transaction_map f = function
  | Private_file_succeeded value -> Private_file_succeeded (f value)
  | Private_file_succeeded_with_cleanup_failure
      { value; cleanup_failure } ->
    Private_file_succeeded_with_cleanup_failure
      { value = f value; cleanup_failure }
  | Private_file_failed error -> Private_file_failed error
  | Private_file_failed_with_cleanup_failure { error; cleanup_failure } ->
    Private_file_failed_with_cleanup_failure { error; cleanup_failure }
;;

let private_jsonl_with_fd_outcome ~close_operation ~close_fd fd f =
  match f () with
  | Ok value ->
    (match private_jsonl_capture close_operation (fun () -> close_fd fd) with
     | Ok () -> Private_file_succeeded value
     | Error cleanup_failure ->
       Private_file_succeeded_with_cleanup_failure
         { value; cleanup_failure })
  | Error error ->
    (match private_jsonl_capture close_operation (fun () -> close_fd fd) with
     | Ok () -> Private_file_failed error
     | Error cleanup_failure ->
       Private_file_failed_with_cleanup_failure
         { error; cleanup_failure })
  | exception exception_ ->
    let backtrace = Printexc.get_raw_backtrace () in
    (match private_jsonl_capture close_operation (fun () -> close_fd fd) with
     | Ok () -> Printexc.raise_with_backtrace exception_ backtrace
     | Error cleanup_failure ->
       let combined, combined_backtrace =
         Eio.Exn.combine
           (exception_, backtrace)
           (cleanup_failure.exception_, cleanup_failure.backtrace)
       in
       Printexc.raise_with_backtrace combined combined_backtrace)
;;

let private_jsonl_add_cleanup_failure error cleanup_failure =
  match error with
  | Transaction_settlement_failed { primary; cleanup_failures } ->
    Transaction_settlement_failed
      { primary; cleanup_failures = cleanup_failures @ [ cleanup_failure ] }
  | (Stable_lock_contended _
    | Unexpected_stable_lock_permissions _
    | Invalid_stable_lock_state _
    | Cursor_mismatch _
    | Unexpected_transaction_file_kind _
    | Ambiguous_transaction_file_identity _
    | Transaction_path_binding_changed _
    | Transaction_content_changed _
    | Incomplete_transaction_tail _
    | Invalid_transaction_suffix
    | Private_jsonl_operation_failed _
    | Rewrite_stage_failed _
    | Rewrite_published_durability_unknown _
    | Transaction_append_failed _) as primary ->
    Transaction_settlement_failed
      { primary = Transaction_failed primary
      ; cleanup_failures = [ cleanup_failure ]
      }
;;

let private_jsonl_settlement_failed ~success result cleanup_failure =
  match result with
  | Ok value ->
    Error
      (Transaction_settlement_failed
         { primary = Transaction_succeeded (success value)
         ; cleanup_failures = [ cleanup_failure ]
         })
  | Error error -> Error (private_jsonl_add_cleanup_failure error cleanup_failure)
;;

let private_jsonl_with_fd ~close_operation ~close_fd ~success fd f =
  match private_jsonl_with_fd_outcome ~close_operation ~close_fd fd f with
  | Private_file_succeeded value -> Ok value
  | Private_file_failed error -> Error error
  | Private_file_succeeded_with_cleanup_failure
      { value; cleanup_failure } ->
    private_jsonl_settlement_failed ~success (Ok value) cleanup_failure
  | Private_file_failed_with_cleanup_failure { error; cleanup_failure } ->
    Error (private_jsonl_add_cleanup_failure error cleanup_failure)
;;

let lock_suffix = ".lock"

let is_lock_name name =
  String.length name > String.length lock_suffix && String.ends_with ~suffix:lock_suffix name
;;

let private_jsonl_lock_path path = path ^ lock_suffix

type private_jsonl_transaction_io_for_testing =
  { before_sync_parent : string -> unit
  ; close_fd : Unix.file_descr -> unit
  }

let private_jsonl_transaction_unix_io =
  { before_sync_parent = (fun _dir -> ()); close_fd = Unix.close }
;;

let private_jsonl_stable_lock_ready_marker = "\xA5"

type private_jsonl_stable_lock_state =
  | Stable_lock_initializing
  | Stable_lock_ready

type private_jsonl_stable_lock_creation =
  | Stable_lock_created
  | Stable_lock_existing

type private_jsonl_stable_lock =
  { fd : Unix.file_descr
  ; creation : private_jsonl_stable_lock_creation
  }

let private_jsonl_open_stable_lock lock_path =
  match
    private_jsonl_capture Open_stable_lock (fun () ->
      Unix.openfile
        lock_path
        [ Unix.O_RDWR; Unix.O_CREAT; Unix.O_EXCL; Unix.O_CLOEXEC; Unix.O_NONBLOCK ]
        0o600)
  with
  | Ok fd -> Ok { fd; creation = Stable_lock_created }
  | Error failure ->
    (match failure.exception_ with
     | Unix.Unix_error (error, _, _) when error = Unix.EEXIST ->
       (match private_jsonl_capture Inspect_stable_lock (fun () -> Unix.lstat lock_path) with
        | Error failure -> Error (Private_jsonl_operation_failed failure)
        | Ok stats when stats.Unix.st_kind <> Unix.S_REG ->
          Error (Unexpected_transaction_file_kind stats.Unix.st_kind)
        | Ok _ ->
          private_jsonl_capture Open_stable_lock (fun () ->
            Unix.openfile lock_path [ Unix.O_RDWR; Unix.O_CLOEXEC; Unix.O_NONBLOCK ] 0)
          |> Result.map (fun fd -> { fd; creation = Stable_lock_existing })
          |> Result.map_error (fun failure -> Private_jsonl_operation_failed failure))
     (* DET-OK: [exn] is open. Every non-EEXIST open failure remains typed. *)
     | _ -> Error (Private_jsonl_operation_failed failure))
;;

let rec private_jsonl_write_substring_all fd value offset =
  if offset < String.length value
  then
    match Unix.write_substring fd value offset (String.length value - offset) with
    | 0 ->
      raise
        (Unix.Unix_error
           (Unix.EIO, "write", "private JSONL stable lock made no progress"))
    | count -> private_jsonl_write_substring_all fd value (offset + count)
    | exception Unix.Unix_error (Unix.EINTR, _, _) ->
      private_jsonl_write_substring_all fd value offset
;;

let private_jsonl_read_stable_lock_state path fd =
  match private_jsonl_capture Read_stable_lock_state (fun () -> Unix.fstat fd) with
  | Error failure -> Error (Private_jsonl_operation_failed failure)
  | Ok stats ->
    let observed_length = stats.Unix.st_size in
    if observed_length = 0
    then Ok Stable_lock_initializing
    else if observed_length <> String.length private_jsonl_stable_lock_ready_marker
    then Error (Invalid_stable_lock_state { path; observed_length })
    else
      (match private_jsonl_capture Read_stable_lock_state (fun () ->
         let bytes = Bytes.create observed_length in
         (* fire-and-forget: seek target is fixed at 0; a failed lseek surfaces as a short/garbage read below *)
         ignore (Unix.lseek fd 0 Unix.SEEK_SET : int);
         let rec read_all offset =
           if offset = observed_length
           then ()
           else
             match Unix.read fd bytes offset (observed_length - offset) with
             | 0 -> raise End_of_file
             | count -> read_all (offset + count)
             | exception Unix.Unix_error (Unix.EINTR, _, _) -> read_all offset
         in
         read_all 0;
         Bytes.unsafe_to_string bytes)
       with
       | Error failure -> Error (Private_jsonl_operation_failed failure)
       | Ok marker ->
         if String.equal marker private_jsonl_stable_lock_ready_marker
         then Ok Stable_lock_ready
         else Error (Invalid_stable_lock_state { path; observed_length }))
;;

let private_jsonl_sync_stable_lock fd =
  private_jsonl_capture Sync_stable_lock (fun () -> Unix.fsync fd)
  |> Result.map_error (fun failure -> Private_jsonl_operation_failed failure)
;;

let private_jsonl_initialize_stable_lock ~io ~dir fd =
  let open Result.Syntax in
  let* () = private_jsonl_sync_stable_lock fd in
  let* () =
    private_jsonl_capture Sync_stable_lock_parent (fun () ->
      io.before_sync_parent dir;
      fsync_parent_directory dir)
    |> Result.map_error (fun failure -> Private_jsonl_operation_failed failure)
  in
  let* () =
    private_jsonl_capture Write_stable_lock_state (fun () ->
      (* fire-and-forget: seek target is fixed at 0; a failed lseek surfaces as a short write below *)
      ignore (Unix.lseek fd 0 Unix.SEEK_SET : int);
      private_jsonl_write_substring_all
        fd
        private_jsonl_stable_lock_ready_marker
        0)
    |> Result.map_error (fun failure -> Private_jsonl_operation_failed failure)
  in
  private_jsonl_sync_stable_lock fd
;;

let private_jsonl_prepare_stable_lock ~io ~dir ~path stable_lock =
  let open Result.Syntax in
  let* () =
    match stable_lock.creation with
    | Stable_lock_created ->
      private_jsonl_capture Set_stable_lock_permissions (fun () ->
        Unix.fchmod stable_lock.fd 0o600)
      |> Result.map_error (fun failure -> Private_jsonl_operation_failed failure)
    | Stable_lock_existing -> Ok ()
  in
  let* permissions =
    private_jsonl_capture Inspect_stable_lock (fun () ->
      (Unix.fstat stable_lock.fd).Unix.st_perm land 0o7777)
    |> Result.map_error (fun failure -> Private_jsonl_operation_failed failure)
  in
  if permissions <> 0o600
  then Error (Unexpected_stable_lock_permissions { path; actual = permissions })
  else
    let* state = private_jsonl_read_stable_lock_state path stable_lock.fd in
    match state with
    | Stable_lock_initializing ->
      private_jsonl_initialize_stable_lock ~io ~dir stable_lock.fd
    | Stable_lock_ready -> Ok ()
;;

let private_jsonl_same_identity left right =
  Int.equal left.Unix.st_dev right.Unix.st_dev
  && Int.equal left.Unix.st_ino right.Unix.st_ino
;;

let private_jsonl_validate_unique_regular_binding ~path ~path_stats ~fd_stats =
  if path_stats.Unix.st_kind <> Unix.S_REG
  then Error (Unexpected_transaction_file_kind path_stats.Unix.st_kind)
  else if fd_stats.Unix.st_kind <> Unix.S_REG
  then Error (Unexpected_transaction_file_kind fd_stats.Unix.st_kind)
  else if path_stats.Unix.st_nlink <> 1
  then
    Error
      (Ambiguous_transaction_file_identity
         { path; link_count = path_stats.Unix.st_nlink })
  else if fd_stats.Unix.st_nlink <> 1
  then
    Error
      (Ambiguous_transaction_file_identity
         { path; link_count = fd_stats.Unix.st_nlink })
  else if not (private_jsonl_same_identity path_stats fd_stats)
  then Error (Transaction_path_binding_changed { path })
  else Ok ()
;;

let private_jsonl_validate_open_binding ~operation ~path fd =
  match private_jsonl_capture operation (fun () -> Unix.lstat path, Unix.fstat fd) with
  | Error failure -> Error (Private_jsonl_operation_failed failure)
  | Ok (path_stats, fd_stats) ->
    private_jsonl_validate_unique_regular_binding ~path ~path_stats ~fd_stats
;;

let rec try_lock_whole_file fd =
  match Unix.lockf fd Unix.F_TLOCK 0 with
  | () -> true
  | exception Unix.Unix_error (Unix.EINTR, _, _) -> try_lock_whole_file fd
  | exception Unix.Unix_error ((Unix.EACCES | Unix.EAGAIN), _, _) -> false
;;

let with_private_jsonl_stable_lock_fd ~io ~success requested_path f =
  let requested_dir = Filename.dirname requested_path in
  run_blocking_private_file_transaction
    ~label:"fs-compat-private-jsonl-transaction"
    ~path:requested_path
    (fun () ->
       match private_jsonl_capture Create_parent_directory (fun () ->
         test_exec_home_guard ~op:"private_jsonl_transaction" requested_path;
         mkdir_p_unix requested_dir)
       with
       | Error failure -> Error (Private_jsonl_operation_failed failure)
       | Ok () ->
         (match private_jsonl_capture Canonicalize_parent_directory (fun () ->
            Unix.realpath requested_dir)
          with
          | Error failure -> Error (Private_jsonl_operation_failed failure)
          | Ok dir ->
            let path = Filename.concat dir (Filename.basename requested_path) in
            let lock_path = private_jsonl_lock_path path in
            let path_mu = get_append_path_mutex path in
            Stdlib.Mutex.protect path_mu (fun () ->
              match private_jsonl_open_stable_lock lock_path with
              | Error _ as error -> error
              | Ok stable_lock ->
                private_jsonl_with_fd
                  ~close_operation:Close_stable_lock
                  ~close_fd:io.close_fd
                  ~success
                  stable_lock.fd
                  (fun () ->
                     let open Result.Syntax in
                     let* () =
                       private_jsonl_validate_open_binding
                         ~operation:Inspect_stable_lock
                         ~path:lock_path
                         stable_lock.fd
                     in
                     let* acquired =
                       private_jsonl_capture Acquire_stable_lock (fun () ->
                         try_lock_whole_file stable_lock.fd)
                       |> Result.map_error (fun failure ->
                         Private_jsonl_operation_failed failure)
                     in
                     if not acquired
                     then Error (Stable_lock_contended { lock_path })
                     else
                       let* () =
                         private_jsonl_validate_open_binding
                           ~operation:Inspect_stable_lock
                           ~path:lock_path
                           stable_lock.fd
                       in
                       let* () =
                         private_jsonl_prepare_stable_lock
                           ~io
                           ~dir
                           ~path:lock_path
                           stable_lock
                       in
                       f ~dir ~path ~lock_fd:stable_lock.fd))))
;;

let with_private_jsonl_stable_lock ~io ~success requested_path f =
  with_private_jsonl_stable_lock_fd ~io ~success requested_path
    (fun ~dir ~path ~lock_fd:_ -> f ~dir ~path)
;;

let with_private_jsonl_identified_stable_lock ~io ~success requested_path f =
  with_private_jsonl_stable_lock_fd ~io ~success requested_path
    (fun ~dir ~path ~lock_fd ->
       match private_jsonl_capture Inspect_stable_lock (fun () -> Unix.fstat lock_fd) with
       | Error failure -> Error (Private_jsonl_operation_failed failure)
       | Ok lock_identity -> f ~dir ~path ~lock_identity)
;;

(* The stable lock opens [realpath dirname / basename ^ lock_suffix]. Resolving
   this spelling through the kernel reaches that same directory entry. *)
let private_jsonl_requested_lock_path requested_path =
  private_jsonl_lock_path
    (Filename.concat (Filename.dirname requested_path) (Filename.basename requested_path))
;;

let private_jsonl_cursor_of_stats stats =
  if stats.Unix.st_kind <> Unix.S_REG
  then Error (Unexpected_transaction_file_kind stats.Unix.st_kind)
  else
    Ok
      (Private_jsonl_cursor.Present
         { device = stats.Unix.st_dev
         ; inode = stats.Unix.st_ino
         ; end_offset = stats.Unix.st_size
         })
;;
