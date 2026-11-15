open Fs_compat_internal
open Fs_compat_base_io
open Fs_compat_owned_file
open Fs_compat_path_ops
open Fs_compat_jsonl_read
open Fs_compat_durable_append
open Fs_compat_private_jsonl_transaction
open Fs_compat_private_jsonl_write

type 'a private_jsonl_recovery_validation =
  | Recovery_authorized
  | Recovery_refused of 'a

type 'a private_jsonl_recovered =
  | Recovered_prefix of string
  | Recovery_result of 'a

type private_file_locking = Wait_for_lock | Try_lock

type 'kept private_jsonl_rows_read =
  | Rows_after_cursor of 'kept
  | Rows_from_start

type 'kept private_jsonl_rows_from_cursor =
  { read : 'kept private_jsonl_rows_read
  ; rows : string
  ; rows_end : Private_jsonl_cursor.t
  }

(* Where a suffix goes. A JSONL plan writes after the last row: bytes after
   the last newline are an append that stopped part way, never a row, and are
   cut first, as [append_private_jsonl_durable_locked_result] cuts them. *)
type suffix_start =
  | After_every_byte
  | After_last_row

(* Where a locked update starts reading, and the decision it hands the bytes
   to. One constructor per start, so a tail read cannot also name a cursor. *)
type 'a private_file_read_plan =
  | Read_whole_file of (string -> string option * 'a)
  | Read_tail_rows of int * (string -> string option * 'a)
  | Read_after_cursor :
      (Private_jsonl_cursor.t * 'kept) option
      * ('kept private_jsonl_rows_from_cursor -> string option * 'a)
      -> 'a private_file_read_plan

let with_private_path_lock ~locking ~path mutex f =
  match locking with
  | Wait_for_lock -> Stdlib.Mutex.protect mutex f
  | Try_lock ->
    if not (Stdlib.Mutex.try_lock mutex) then
      raise (Sys_error ("private file is busy: " ^ path));
    Fun.protect ~finally:(fun () -> Stdlib.Mutex.unlock mutex) f

let update_private_file_durable_locked_with_io ?(create=true) ?(locking=Wait_for_lock) ?validate_prefix
    ?(confirm_existing=(fun () -> false)) ?(verify_content=false)
    ?(append_io=durable_append_unix_io) ~io path (plan : _ private_file_read_plan) =
  test_exec_home_guard ~op:"update_private_file_durable_locked" path;
  let dir = Filename.dirname path in
  if create then mkdir_p_memoized dir;
  let path_mu = get_append_path_mutex path in
  run_blocking_private_file_transaction
    ~label:"fs-compat-durable-update"
    ~path
    (fun () ->
    with_private_path_lock ~locking ~path path_mu (fun () ->
      let require_binding = function
        | Ok () -> ()
        | Error (Private_jsonl_operation_failed failure) ->
          Printexc.raise_with_backtrace failure.exception_ failure.backtrace
        | Error ((Stable_lock_contended _ | Unexpected_stable_lock_permissions _
            | Invalid_stable_lock_state _ | Cursor_mismatch _
            | Unexpected_transaction_file_kind _ | Ambiguous_transaction_file_identity _
            | Transaction_path_binding_changed _
            | Transaction_content_changed _ | Incomplete_transaction_tail _
            | Invalid_transaction_suffix | Rewrite_stage_failed _
            | Rewrite_published_durability_unknown _ | Transaction_settlement_failed _
            | Transaction_append_failed _) as error) ->
          raise (Sys_error (private_jsonl_transaction_error_to_string error))
      in
      (* A pathname cannot authorize bytes read from a different opened inode.
         Keep the creating updater's setup/read exception contract, while
         sharing the existing-only updater's canonical binding validation. *)
      (match Unix.lstat path with
       | stats -> require_binding (private_jsonl_validate_unique_regular_binding
           ~path ~path_stats:stats ~fd_stats:stats)
       | exception Unix.Unix_error (Unix.ENOENT, _, _) when create -> ());
      let fd =
        Unix.openfile path
          ([ Unix.O_RDWR; Unix.O_APPEND; Unix.O_CLOEXEC; Unix.O_NONBLOCK ] @ if create then [Unix.O_CREAT] else [])
          0o600
      in
      private_jsonl_with_fd_outcome
        ~close_operation:Close_transaction_data
        ~close_fd:io.close_fd
        fd
        (fun () ->
           let validate_binding () = require_binding
             (private_jsonl_validate_open_binding ~operation:Inspect_transaction_path ~path fd) in
           validate_binding ();
           Unix.fchmod fd 0o600;
           let sync_parent () = io.before_sync_parent dir; fsync_parent_directory dir in
           (match locking with Wait_for_lock -> sync_parent () | Try_lock -> ());
           (* See Unix.lseek: only the file-position side effect is required. *)
           ignore (Unix.lseek fd 0 Unix.SEEK_SET : int);
           (match locking with
            | Wait_for_lock -> lock_whole_file fd
            | Try_lock ->
              if not (try_lock_whole_file fd) then
                raise (Sys_error ("private file is busy: " ^ path)));
           validate_binding ();
           (* A try-lock caller must be able to reject contention before the
              parent fsync, while still syncing before touching payload bytes. *)
           (match locking with Try_lock -> sync_parent () | Wait_for_lock -> ());
           (* See Unix.lseek: only the file-position side effect is required. *)
           ignore (Unix.lseek fd 0 Unix.SEEK_SET : int);
           let before_read = Unix.fstat fd in
           (* A row starts at the first byte of the file and after each
              newline. *)
           let row_starts_at offset =
             offset = 0
             || Char.equal (private_jsonl_read_byte fd (Bytes.create 1) (offset - 1)) '\n'
           in
           (* Where the read starts, whether that byte starts a row, and the
              decision over the bytes read from there. *)
           let from, starts_at_row, suffix_start, decide =
             match plan with
             | Read_whole_file decide -> 0, true, After_every_byte, decide
             | Read_tail_rows (max_bytes, decide) ->
               let from = Int.max 0 (before_read.Unix.st_size - max_bytes) in
               (* Only a tail read may start inside a row; it drops that
                  fragment. *)
               from, row_starts_at from, After_every_byte, decide
             | Read_after_cursor (after, decide) ->
               (* A cursor of another file, one past this file's end, or one
                  where no row of this file starts is not the end of rows read
                  from it: the read starts at the first byte, and what the
                  caller kept with that cursor is not handed back. *)
               let read, from =
                 match after with
                 | None -> Rows_from_start, 0
                 | Some (cursor, kept) ->
                   (match
                      Private_jsonl_cursor.prefix_end_offset
                        cursor
                        ~device:before_read.Unix.st_dev
                        ~inode:before_read.Unix.st_ino
                        ~file_length:before_read.Unix.st_size
                    with
                    | Some end_offset when row_starts_at end_offset ->
                      Rows_after_cursor kept, end_offset
                    | Some _ | None -> Rows_from_start, 0)
               in
               ( from
               , true
               , After_last_row
               , fun existing ->
                   let rows_length = private_jsonl_last_complete_row_length existing in
                   let rows =
                     if rows_length = String.length existing
                     then existing
                     else String.sub existing 0 rows_length
                   in
                   decide
                     { read
                     ; rows
                     ; rows_end =
                         Private_jsonl_cursor.Present
                           { device = before_read.Unix.st_dev
                           ; inode = before_read.Unix.st_ino
                           ; end_offset = from + rows_length
                           }
                     } )
           in
           ignore (Unix.lseek fd from Unix.SEEK_SET : int);
           let existing = read_fd_chunks fd in
           let same_snapshot left right =
             left.Unix.st_dev=right.Unix.st_dev && left.st_ino=right.st_ino
             && left.st_size=right.st_size && left.st_mtime=right.st_mtime
             && left.st_ctime=right.st_ctime in
           let require_snapshot expected =
             validate_binding ();
             if verify_content && not (same_snapshot expected (Unix.fstat fd)) then
               raise (Sys_error "private file changed during reconciliation") in
           require_snapshot before_read;
           let verify_bytes expected =
             validate_binding ();
             let before = Unix.fstat fd in
             ignore (Unix.lseek fd 0 Unix.SEEK_SET : int);
             let actual = read_fd_chunks fd in
             if not (String.equal expected actual) then
               raise (Sys_error "private file contents changed during reconciliation");
             require_snapshot before in
           let existing =
             if starts_at_row then existing
             else match String.index_opt existing '\n' with
             | None -> existing
             | Some newline ->
               String.sub existing (newline + 1) (String.length existing - newline - 1)
           in
           validate_binding ();
           let recovered = match validate_prefix with
             | None -> Ok (Recovered_prefix existing)
             | Some validate_prefix ->
               let complete_length = private_jsonl_last_complete_row_length existing in
               let prefix = if complete_length = String.length existing then existing
                 else String.sub existing 0 complete_length in
               let validation = validate_prefix prefix in
               validate_binding ();
               (match validation with
                | Recovery_refused result -> Ok (Recovery_result result)
                | Recovery_authorized ->
                  if complete_length = String.length existing then Ok (Recovered_prefix prefix)
                  else
                    let open Result.Syntax in
                    let failure append_failure = {append_failure; rollback_failures=[]} in
                    let* () = run_unix_io ~operation:Incomplete_tail_truncate (fun () ->
                      Unix.ftruncate fd complete_length) |> Result.map_error failure in
                    let* () = run_unix_io ~operation:Incomplete_tail_fsync (fun () -> Unix.fsync fd)
                      |> Result.map_error failure in
                    Ok (Recovered_prefix prefix)) in
           Result.bind recovered (function
           | Recovery_result result -> validate_binding (); Ok result
           | Recovered_prefix existing ->
           validate_binding ();
           let suffix, result = decide existing in
           validate_binding ();
           if verify_content then (require_snapshot before_read; verify_bytes existing);
           match suffix with
            | None ->
              if not (confirm_existing ()) then Ok result else
              run_unix_io ~operation:Append_fsync (fun () -> append_io.fsync fd)
              |> Result.map_error (fun append_failure -> {append_failure;rollback_failures=[]})
              |> Result.map (fun () ->
                validate_binding ();
                if verify_content then (require_snapshot before_read; verify_bytes existing);
                result)
            | Some suffix ->
              (* See Unix.lseek: only the file-position side effect is required. *)
              let file_length = Unix.lseek fd 0 Unix.SEEK_END in
              let append_from =
                match suffix_start with
                | After_every_byte -> Ok file_length
                | After_last_row ->
                  let rows_end = from + private_jsonl_last_complete_row_length existing in
                  if rows_end = file_length
                  then Ok rows_end
                  else
                    let open Result.Syntax in
                    let failure append_failure = { append_failure; rollback_failures = [] } in
                    let* () =
                      run_unix_io ~operation:Incomplete_tail_truncate (fun () ->
                        Unix.ftruncate fd rows_end)
                      |> Result.map_error failure
                    in
                    let* () =
                      run_unix_io ~operation:Incomplete_tail_fsync (fun () -> Unix.fsync fd)
                      |> Result.map_error failure
                    in
                    Stdlib.Printf.eprintf
                      "[fs_compat] WARN: cut an incomplete JSONL tail path=%s cut_bytes=%d kept_bytes=%d\n%!"
                      path
                      (file_length - rows_end)
                      rows_end;
                    Ok rows_end
              in
              Result.bind append_from (fun original_length ->
                append_fd_durable
                  ~io:append_io
                  ~fd
                  ~original_length
                  suffix
                |> Result.map (fun () ->
                  validate_binding ();
                  if verify_content then verify_bytes (existing ^ suffix);
                  result))))))
;;

type 'a private_file_decision =
  | Refuse_update of 'a
  | Confirm_existing of 'a
  | Append_confirmed of string * 'a

let reconcile_private_file_durable_locked_with_append_io ~locking ~append_io path decide =
  let confirmation = ref false in
  update_private_file_durable_locked_with_io ~locking
    ~verify_content:true ~confirm_existing:(fun () -> !confirmation) ~append_io
    ~io:private_jsonl_transaction_unix_io path (Read_whole_file (fun existing ->
      match decide existing with
      | Refuse_update result -> None,result
      | Confirm_existing result -> confirmation := true; None,result
      | Append_confirmed (suffix,result) -> Some suffix,result))
;;

let reconcile_private_file_durable_locked_with_append_io_for_testing ~append_io path decide =
  reconcile_private_file_durable_locked_with_append_io ~locking:Wait_for_lock ~append_io path decide
;;

let reconcile_private_file_durable_locked_result ?(locking=Wait_for_lock) path decide =
  reconcile_private_file_durable_locked_with_append_io ~locking
    ~append_io:durable_append_unix_io path decide
;;

let update_private_file_durable_locked_result ?(create=true) path decide =
  update_private_file_durable_locked_with_io ~create
    ~io:private_jsonl_transaction_unix_io
    path
    (Read_whole_file decide)
;;

let update_private_jsonl_after_cursor_durable_locked_result ?(create=true) path ~after decide =
  update_private_file_durable_locked_with_io ~create
    ~io:private_jsonl_transaction_unix_io
    path
    (Read_after_cursor (after, decide))
;;

let update_private_file_tail_durable_locked_result path ~max_bytes decide =
  if max_bytes <= 0 then invalid_arg "update_private_file_tail_durable_locked_result";
  update_private_file_durable_locked_with_io
    ~io:private_jsonl_transaction_unix_io path (Read_tail_rows (max_bytes, decide))
;;

let update_private_file_tail_durable_locked_with_append_io_for_testing
    ~append_io path ~max_bytes decide =
  if max_bytes <= 0 then invalid_arg "update_private_file_tail_durable_locked_result";
  update_private_file_durable_locked_with_io ~append_io
    ~io:private_jsonl_transaction_unix_io path (Read_tail_rows (max_bytes, decide))
;;

let recover_and_update_private_jsonl_durable_locked_result ?(create=true) ?(locking=Wait_for_lock) ~validate_prefix path decide =
  update_private_file_durable_locked_with_io ~create ~locking ~validate_prefix
    ~io:private_jsonl_transaction_unix_io path (Read_whole_file decide)
;;

let update_private_file_durable_locked_with_io_for_testing ?(create=true) ~io path decide =
  update_private_file_durable_locked_with_io ~create ~io path (Read_whole_file decide)
;;

let update_existing_private_file_durable_locked_with_io ~io path decide =
  test_exec_home_guard ~op:"update_existing_private_file_durable_locked" path;
  let path_mu = get_append_path_mutex path in
  run_blocking_private_file_transaction
    ~label:"fs-compat-existing-durable-update"
    ~path
    (fun () ->
       Stdlib.Mutex.protect path_mu (fun () ->
         (* Reject special files before opening them; O_NONBLOCK also prevents a
            raced FIFO substitution from blocking before descriptor validation. *)
         let inspected =
           match Unix.lstat path with
           | stats ->
             if stats.Unix.st_kind <> Unix.S_REG
             then Error (Unexpected_transaction_file_kind stats.Unix.st_kind)
             else Ok (Some stats)
           | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok None
           | exception (Eio.Cancel.Cancelled _ as cancellation) -> raise cancellation
           | exception exception_ ->
             Error
               (Private_jsonl_operation_failed
                  (private_jsonl_failure Inspect_transaction_path exception_))
         in
         match inspected with
         | Error error -> Private_file_failed error
         | Ok None -> Private_file_succeeded None
         | Ok (Some _) ->
           match
             private_jsonl_open_existing ~close_fd:io.close_fd path
               [ Unix.O_RDWR; Unix.O_APPEND ]
           with
           | Error error -> Private_file_failed error
           | Ok None -> Private_file_succeeded None
           | Ok (Some fd) ->
             private_jsonl_with_fd_outcome
               ~close_operation:Close_transaction_data
               ~close_fd:io.close_fd fd
               (fun () ->
                  let open Result.Syntax in
                  let* () =
                    private_jsonl_capture Read_transaction_data (fun () ->
                      ignore (Unix.lseek fd 0 Unix.SEEK_SET : int);
                      lock_whole_file fd)
                    |> Result.map_error (fun failure ->
                      Private_jsonl_operation_failed failure)
                  in
                  let* () =
                    private_jsonl_validate_open_binding
                      ~operation:Inspect_transaction_path ~path fd
                  in
                  let* existing =
                    private_jsonl_capture Read_transaction_data (fun () ->
                      ignore (Unix.lseek fd 0 Unix.SEEK_SET : int);
                      read_fd_chunks fd)
                    |> Result.map_error (fun failure ->
                      Private_jsonl_operation_failed failure)
                  in
                  let suffix, result = decide existing in
                  match suffix with
                  | None -> Ok (Some result)
                  | Some suffix ->
                    let* original_length =
                      private_jsonl_capture Read_transaction_data (fun () ->
                        Unix.lseek fd 0 Unix.SEEK_END)
                      |> Result.map_error (fun failure ->
                        Private_jsonl_operation_failed failure)
                    in
                    append_fd_durable ~io:durable_append_unix_io
                      ~fd ~original_length suffix
                    |> Result.map_error (fun error -> Transaction_append_failed error)
                    |> Result.map (fun () -> Some result))))
;;

let update_existing_private_file_durable_locked_result path decide =
  update_existing_private_file_durable_locked_with_io
    ~io:private_jsonl_transaction_unix_io path decide
;;

let update_existing_private_file_durable_locked_with_io_for_testing ~io path decide =
  update_existing_private_file_durable_locked_with_io ~io path decide
;;

let rewrite_private_file_durable_locked_result path decide =
  test_exec_home_guard ~op:"rewrite_private_file_durable_locked" path;
  let dir = Filename.dirname path in
  mkdir_p_memoized dir;
  let path_mu = get_append_path_mutex path in
  run_blocking_private_file_transaction
    ~label:"fs-compat-durable-rewrite"
    ~path
    (fun () ->
    Stdlib.Mutex.protect path_mu (fun () ->
      let existing = Option.value (load_file_opt path) ~default:"" in
      let content, result = decide existing in
      match content with
      | None -> Ok result
      | Some content ->
        (match save_file_atomic path content with
         | Ok () -> Ok result
         | Error message -> Error message)))
;;

type private_jsonl_append_error =
  | Incomplete_jsonl_tail
  | Incomplete_jsonl_tail_truncate_failed of durable_append_failure
  | Existing_jsonl_refused of string
  | Invalid_jsonl_suffix
  | Negative_expected_end_offset of int
  | End_offset_mismatch of
      { expected : int
      ; actual : int
      }
  | Durable_jsonl_append_failed of durable_append_error

let private_jsonl_append_error_to_string = function
  | Incomplete_jsonl_tail ->
    "existing JSONL file ends with an incomplete row"
  | Incomplete_jsonl_tail_truncate_failed failure ->
    Printf.sprintf
      "existing JSONL file ends with an incomplete row that could not be cut: %s"
      (durable_append_failure_to_string failure)
  | Existing_jsonl_refused detail -> "existing JSONL refused: " ^ detail
  | Invalid_jsonl_suffix ->
    "JSONL append suffix must be non-empty and newline-terminated"
  | Negative_expected_end_offset offset ->
    Printf.sprintf "expected JSONL end offset must be non-negative: %d" offset
  | End_offset_mismatch { expected; actual } ->
    Printf.sprintf
      "JSONL end offset mismatch: expected %d, observed %d"
      expected
      actual
  | Durable_jsonl_append_failed error -> durable_append_error_to_string error
;;

(* A final fragment with no '\n' is what an append leaves when the process
   dies part way through it, so it is never a row. The rows end right after
   the last '\n'. Called under the append lock. *)
let read_jsonl_rows_end fd =
  match
    (* See Unix.lseek: only the file-position side effect is required. *)
    ignore (Unix.lseek fd 0 Unix.SEEK_SET : int);
    read_fd_chunks fd
  with
  | bytes ->
    Ok
      (match String.rindex_opt bytes '\n' with
       | Some newline -> newline + 1
       | None -> 0)
  | exception Unix.Unix_error (error, function_name, argument) ->
    Error
      (unix_failure ~operation:Incomplete_tail_read error function_name argument)
;;

(* The caller holds the path mutex, which the other appenders here also take
   ([append_file], [append_jsonl], [update_private_file_durable_locked_result]),
   and the exclusive [lockf], which every durable writer in another process
   takes. No such writer is in the file while it is cut back to [rows_end] and
   fsynced; a writer in another process that takes neither lock is not
   excluded. Returns the length the append then starts from. *)
let cut_incomplete_jsonl_tail ~path ~fd ~end_offset ~rows_end =
  Result.bind
    (run_unix_io ~operation:Incomplete_tail_truncate (fun () ->
       Unix.ftruncate fd rows_end))
    (fun () ->
       Result.map
         (fun () ->
            Stdlib.Printf.eprintf
              "[fs_compat] WARN: cut an incomplete JSONL tail path=%s cut_bytes=%d kept_bytes=%d\n%!"
              path
              (end_offset - rows_end)
              rows_end;
            rows_end)
         (run_unix_io ~operation:Incomplete_tail_fsync (fun () -> Unix.fsync fd)))
;;

(* Called under the append lock; stops after the first row without loading the
   journal. A file with only an incomplete first row is presented as-is. *)
let read_first_jsonl_row fd =
  ignore (Unix.lseek fd 0 Unix.SEEK_SET : int);
  let row = Buffer.create 256 in
  let chunk = Bytes.create 4096 in
  let rec loop () =
    match Unix.read fd chunk 0 (Bytes.length chunk) with
    | 0 -> Buffer.contents row
    | count ->
        (match Bytes.index_opt (Bytes.sub chunk 0 count) '\n' with
         | Some newline -> Buffer.add_subbytes row chunk 0 newline; Buffer.contents row
         | None -> Buffer.add_subbytes row chunk 0 count; loop ())
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> loop () in
  loop ()
;;

let append_private_jsonl_durable_locked_with_expected_end_offset_with_io
      ?validate_first_row
      ~io
      path
      ~expected_end_offset
      suffix
  =
  if String.equal suffix ""
     || not (Char.equal suffix.[String.length suffix - 1] '\n')
  then Private_file_failed Invalid_jsonl_suffix
  else
    match expected_end_offset with
    | Some offset when offset < 0 ->
      Private_file_failed (Negative_expected_end_offset offset)
    | _ ->
      run_blocking_private_file_transaction
        ~label:"fs-compat-durable-append"
        ~path
        (fun () ->
           test_exec_home_guard ~op:"append_private_jsonl_durable_locked" path;
           let dir = Filename.dirname path in
           Mkdir_memo.mkdir_p_memoized
             ~mkdir_p:(fun dir ->
               test_exec_home_guard ~op:"mkdir_p" dir;
               mkdir_p_unix dir)
             dir;
           let path_mu = get_append_path_mutex path in
           Stdlib.Mutex.protect path_mu (fun () ->
             match
               (match Unix.lstat path with
                | stats when stats.Unix.st_kind <> Unix.S_REG ->
                  Error
                    (Existing_jsonl_refused
                       ("private JSONL store is not a regular file: "
                        ^ file_kind_to_string stats.Unix.st_kind))
                | stats when stats.Unix.st_nlink <> 1 ->
                  Error
                    (Existing_jsonl_refused
                       (Printf.sprintf
                          "private JSONL store has ambiguous hard-link identity: %s (links=%d)"
                          path
                          stats.Unix.st_nlink))
                | _ -> Ok ()
                | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok ())
             with
             | Error error -> Private_file_failed error
             | Ok () ->
             let fd =
               Unix.openfile path
                 [ Unix.O_RDWR; Unix.O_CREAT; Unix.O_APPEND; Unix.O_CLOEXEC; Unix.O_NONBLOCK ]
                 0o600
             in
             private_jsonl_with_fd_outcome
               ~close_operation:Close_transaction_data
               ~close_fd:io.close_fd
               fd
               (fun () ->
                  let validate_binding () =
                    match Unix.lstat path, Unix.fstat fd with
                    | path_stats, _ when path_stats.Unix.st_kind <> Unix.S_REG ->
                      Error
                        (Existing_jsonl_refused
                           ("private JSONL store is not a regular file: "
                            ^ file_kind_to_string path_stats.Unix.st_kind))
                    | _, fd_stats when fd_stats.Unix.st_kind <> Unix.S_REG ->
                      Error
                        (Existing_jsonl_refused
                           ("private JSONL store is not a regular file: "
                            ^ file_kind_to_string fd_stats.Unix.st_kind))
                    | path_stats, _ when path_stats.Unix.st_nlink <> 1 ->
                      Error
                        (Existing_jsonl_refused
                           (Printf.sprintf
                              "private JSONL store has ambiguous hard-link identity: %s (links=%d)"
                              path
                              path_stats.Unix.st_nlink))
                    | _, fd_stats when fd_stats.Unix.st_nlink <> 1 ->
                      Error
                        (Existing_jsonl_refused
                           (Printf.sprintf
                              "private JSONL store has ambiguous hard-link identity: %s (links=%d)"
                              path
                              fd_stats.Unix.st_nlink))
                    | path_stats, fd_stats
                      when not (private_jsonl_same_identity path_stats fd_stats) ->
                      Error
                        (Existing_jsonl_refused
                           ("private JSONL store path binding changed during operation: "
                            ^ path))
                    | _ -> Ok ()
                  in
                  let validation =
                    Result.bind (validate_binding ()) (fun () ->
                      Unix.fchmod fd 0o600;
                      fsync_parent_directory dir;
                      (* See Unix.lseek: only the file-position side effect is required. *)
                      ignore (Unix.lseek fd 0 Unix.SEEK_SET : int);
                      lock_whole_file fd;
                      Result.bind (validate_binding ()) (fun () ->
                        let original_length = Unix.lseek fd 0 Unix.SEEK_END in
                        match validate_first_row with
                        | None -> Ok original_length
                        | Some _ when original_length = 0 -> Ok original_length
                        | Some validate ->
                          validate (read_first_jsonl_row fd)
                          |> Result.map (fun () -> original_length)
                          |> Result.map_error (fun detail -> Existing_jsonl_refused detail)))
                  in
                  Result.bind validation (fun original_length ->
                    let tail_is_complete =
                      if original_length = 0
                      then true
                      else (
                        (* See Unix.lseek: only the file-position side effect is required. *)
                        ignore (Unix.lseek fd (original_length - 1) Unix.SEEK_SET : int);
                        let byte = Bytes.create 1 in
                        let rec read_tail () =
                          match Unix.read fd byte 0 1 with
                          | 1 -> Char.equal (Bytes.get byte 0) '\n'
                          | 0 -> false
                          | _ -> false
                          | exception Unix.Unix_error (Unix.EINTR, _, _) -> read_tail ()
                        in
                        read_tail ())
                    in
                    (* An offset names where the rows the caller read end. A
                       fragment after the last '\n' was never a row, so a
                       caller that stopped at that '\n' read every row there
                       is and its append cuts the fragment, as the append
                       without an offset does. A caller that counted the
                       fragment in its offset read something that is not a
                       row, and is refused with the file left as it is. *)
                    let append_from =
                      let truncate_failed failure =
                        Incomplete_jsonl_tail_truncate_failed failure
                      in
                      match tail_is_complete, expected_end_offset with
                      | true, Some expected when expected <> original_length ->
                        Error
                          (End_offset_mismatch
                             { expected; actual = original_length })
                      | true, (Some _ | None) -> Ok original_length
                      | false, Some expected when expected = original_length ->
                        Error Incomplete_jsonl_tail
                      | false, (Some _ | None) ->
                        Result.bind
                          (read_jsonl_rows_end fd
                           |> Result.map_error truncate_failed)
                          (fun rows_end ->
                             match expected_end_offset with
                             | Some expected when expected <> rows_end ->
                               Error
                                 (End_offset_mismatch
                                    { expected; actual = original_length })
                             | Some _ | None ->
                               cut_incomplete_jsonl_tail
                                 ~path
                                 ~fd
                                 ~end_offset:original_length
                                 ~rows_end
                               |> Result.map_error truncate_failed)
                    in
                    (match append_from with
                     | Error _ as error -> error
                     | Ok append_from ->
                       (* See Unix.lseek: only the file-position side effect is required. *)
                       ignore (Unix.lseek fd 0 Unix.SEEK_END : int);
                       append_fd_durable
                         ~io:durable_append_unix_io
                         ~fd
                         ~original_length:append_from
                         suffix
                       |> Result.map_error (fun error ->
                         Durable_jsonl_append_failed error)
                       |> Result.map (fun () ->
                         append_from + String.length suffix))))))
;;

let append_private_jsonl_durable_locked_with_expected_end_offset_result
      path
      ~expected_end_offset
      suffix
  =
  append_private_jsonl_durable_locked_with_expected_end_offset_with_io
    ~io:private_jsonl_transaction_unix_io
    path
    ~expected_end_offset
    suffix
;;

let append_private_jsonl_durable_locked_with_end_offset_result path suffix =
  append_private_jsonl_durable_locked_with_expected_end_offset_result
    path
    ~expected_end_offset:None
    suffix
;;

let append_private_jsonl_durable_locked_at_end_offset_result
      path
      ~expected_end_offset
      suffix
  =
  append_private_jsonl_durable_locked_with_expected_end_offset_result
    path
    ~expected_end_offset:(Some expected_end_offset)
    suffix
;;

let append_private_jsonl_durable_locked_result path suffix =
  append_private_jsonl_durable_locked_with_end_offset_result path suffix
  |> private_file_transaction_map ignore
;;

let append_private_jsonl_durable_locked_validated_result ~validate_first_row path suffix =
  append_private_jsonl_durable_locked_with_expected_end_offset_with_io
    ~validate_first_row
    ~io:private_jsonl_transaction_unix_io
    path ~expected_end_offset:None suffix
  |> private_file_transaction_map ignore
;;

let append_private_jsonl_durable_locked_at_end_offset_with_io_for_testing
      ~io
      path
      ~expected_end_offset
      suffix
  =
  append_private_jsonl_durable_locked_with_expected_end_offset_with_io
    ~io
    path
    ~expected_end_offset:(Some expected_end_offset)
    suffix
;;

let append_jsonl (path : string) (json : Yojson.Safe.t) : unit =
  test_exec_home_guard ~op:"append_jsonl" path;
  let write () =
    Mkdir_memo.mkdir_p_memoized ~mkdir_p:mkdir_p_unix
      (Stdlib.Filename.dirname path);
    let buf = Buffer.create 256 in
    Yojson.Safe.to_buffer buf json;
    Buffer.add_char buf '\n';
    append_file_unix path (Buffer.contents buf)
  in
  (* Keep the path lock and cached-channel lease wholly inside the job.
     The joined result is also the caller's commit-acknowledgement boundary:
     do not add [on_systhread]'s post-write cancellation check here. *)
  match execution_context () with
  | Non_eio -> write ()
  | Eio_fiber ->
    Fs_compat_internal.Systhread_host.run
      ~label:(labelled "fs-compat-append-jsonl" path) write

let append_jsonl_batch (path : string) (jsons : Yojson.Safe.t list) : unit =
  if jsons = [] then ()
  else begin
    test_exec_home_guard ~op:"append_jsonl_batch" path;
    let write () =
      Mkdir_memo.mkdir_p_memoized ~mkdir_p:mkdir_p_unix
        (Stdlib.Filename.dirname path);
      let buf = Buffer.create 4096 in
      List.iter (fun json ->
        Yojson.Safe.to_buffer buf json;
        Buffer.add_char buf '\n'
      ) jsons;
      append_file_unix path (Buffer.contents buf)
    in
    match execution_context () with
    | Non_eio -> write ()
    | Eio_fiber ->
      Fs_compat_internal.Systhread_host.run
        ~label:(labelled "fs-compat-append-jsonl-batch" path) write
  end
;;
