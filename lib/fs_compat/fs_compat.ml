(** Filesystem Compatibility Layer - Eio-native I/O with fallback

    Provides a unified filesystem API for gradual migration from
    blocking Unix I/O to Eio.Path operations.

    Usage:
    1. At server startup: [Fs_compat.set_fs (Eio.Stdenv.fs env)]
    2. In code: [Fs_compat.load_file path] instead of [open_in ...]

    When fs is not set (non-Eio contexts), falls back to blocking Unix I/O.
    This allows incremental migration without changing all call sites at once.

    @since 2026-02 - Keeper Emergent Identity v2.0
*)

open Fs_compat_internal

include Fs_compat_base_io
include Fs_compat_capability_write
include Fs_compat_owned_file
include Fs_compat_owned_inventory
include Fs_compat_owned_reader
include Fs_compat_path_ops
include Fs_compat_jsonl_read
include Fs_compat_durable_append
include Fs_compat_private_jsonl_transaction
include Fs_compat_private_jsonl_write

module Private_jsonl_slice = struct
  type t =
    { bytes : string
    ; end_offset : int
    }

  type error =
    | Negative_offset of int
    | Missing_file_after_offset of int
    | Offset_beyond_end of
        { offset : int
        ; end_offset : int
        }
    | Offset_not_at_row_boundary of int
    | Incomplete_tail of int
    | Non_regular_file of Unix.file_kind
    | Io_failed of exn

  let error_to_string = function
    | Negative_offset offset -> Printf.sprintf "negative JSONL cursor: %d" offset
    | Missing_file_after_offset offset ->
      Printf.sprintf "JSONL store is missing after cursor %d" offset
    | Offset_beyond_end { offset; end_offset } ->
      Printf.sprintf "JSONL cursor %d is beyond end %d" offset end_offset
    | Offset_not_at_row_boundary offset ->
      Printf.sprintf "JSONL cursor %d is not a row boundary" offset
    | Incomplete_tail end_offset ->
      Printf.sprintf "JSONL store has an incomplete tail at end %d" end_offset
    | Non_regular_file kind ->
      "private JSONL store is not a regular file: " ^ file_kind_to_string kind
    | Io_failed exn -> Printexc.to_string exn
  ;;
end

let read_private_jsonl_slice_locked_with_io ~io path ~from =
  let open Private_jsonl_slice in
  if from < 0
  then Private_file_failed (Negative_offset from)
  else
    try
      test_exec_home_guard ~op:"read_private_jsonl_slice_locked" path;
      let path_mu = get_append_path_mutex path in
      run_blocking_private_file_transaction
        ~label:"fs-compat-private-jsonl-read"
        ~path
        (fun () ->
           Stdlib.Mutex.protect path_mu (fun () ->
             match Unix.openfile path [ Unix.O_RDONLY; Unix.O_CLOEXEC; Unix.O_NONBLOCK ] 0 with
             | exception Unix.Unix_error (Unix.ENOENT, _, _) ->
               if from = 0
               then Private_file_succeeded { bytes = ""; end_offset = 0 }
               else Private_file_failed (Missing_file_after_offset from)
             | fd ->
               private_jsonl_with_fd_outcome
                 ~close_operation:Close_transaction_data
                 ~close_fd:io.close_fd
                 fd
                 (fun () ->
                    try
                      let kind = (Unix.fstat fd).Unix.st_kind in
                      if kind <> Unix.S_REG then Error (Non_regular_file kind)
                      else (
                      lock_whole_file_shared fd;
                      let end_offset = Unix.lseek fd 0 Unix.SEEK_END in
                      if from > end_offset
                      then Error (Offset_beyond_end { offset = from; end_offset })
                      else (
                        let byte_at offset =
                          (* See Unix.lseek: only the file-position side effect is required. *)
                          ignore (Unix.lseek fd offset Unix.SEEK_SET : int);
                          let byte = Bytes.create 1 in
                          let rec read () =
                            match Unix.read fd byte 0 1 with
                            | 1 -> Bytes.get byte 0
                            | 0 -> raise End_of_file
                            | count ->
                              invalid_arg
                                (Printf.sprintf
                                   "single-byte JSONL read returned %d bytes"
                                   count)
                            | exception Unix.Unix_error (Unix.EINTR, _, _) ->
                              read ()
                          in
                          read ()
                        in
                        if from > 0
                           && not (Char.equal (byte_at (from - 1)) '\n')
                        then Error (Offset_not_at_row_boundary from)
                        else if
                          end_offset > 0
                          && not (Char.equal (byte_at (end_offset - 1)) '\n')
                        then Error (Incomplete_tail end_offset)
                        else (
                          let length = end_offset - from in
                          (* See Unix.lseek: only the file-position side effect is required. *)
                          ignore (Unix.lseek fd from Unix.SEEK_SET : int);
                          let bytes = Bytes.create length in
                          let rec read_all offset =
                            if offset = length
                            then ()
                            else
                              match Unix.read fd bytes offset (length - offset) with
                              | 0 -> raise End_of_file
                              | count -> read_all (offset + count)
                              | exception Unix.Unix_error (Unix.EINTR, _, _) ->
                                read_all offset
                          in
                          read_all 0;
                          Ok
                            { bytes = Bytes.unsafe_to_string bytes
                            ; end_offset
                            })))
                    with
                    | Eio.Cancel.Cancelled _ as cancellation -> raise cancellation
                    | exn -> Error (Io_failed exn))))
    with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | exn -> Private_file_failed (Io_failed exn)
;;

let read_private_jsonl_slice_locked_result path ~from =
  read_private_jsonl_slice_locked_with_io
    ~io:private_jsonl_transaction_unix_io
    path
    ~from
;;

let read_private_jsonl_slice_locked_with_io_for_testing ~io path ~from =
  read_private_jsonl_slice_locked_with_io ~io path ~from
;;

module Private_jsonl_rows = struct
  type t =
    | Rows_missing
    | Rows_present of
        { rows : string
        ; rows_end : int
        ; end_offset : int
        }

  type error =
    | Non_regular_file of Unix.file_kind
    | Io_failed of exn

  let error_to_string = function
    | Non_regular_file kind ->
      "private JSONL store is not a regular file: " ^ file_kind_to_string kind
    | Io_failed exn -> Printexc.to_string exn
  ;;
end

(* The writer's framing rule applied by a reader: under the same per-path
   mutex and a shared cross-process lock, the file is every row that ends in
   '\n' plus, at most, one fragment a crashed append left behind (the
   exclusive lock means no append is in progress while the shared lock is
   held). The fragment is reported by [rows_end < end_offset], never returned
   as bytes, so the caller sees exactly the rows a later append would build
   on. *)
let read_private_jsonl_locked_with_errors
      ~io ~on_missing ~non_regular ~operation_failed path read =
  let capture operation f =
    private_jsonl_capture operation f |> Result.map_error operation_failed
  in
  try
    test_exec_home_guard ~op:"read_private_jsonl_rows_locked" path;
    let path_mu = get_append_path_mutex path in
    run_blocking_private_file_transaction
      ~label:"fs-compat-private-jsonl-rows-read"
      ~path
      (fun () ->
         Stdlib.Mutex.protect path_mu (fun () ->
           match capture Open_transaction_data (fun () ->
             match Unix.openfile path [ Unix.O_RDONLY; Unix.O_CLOEXEC; Unix.O_NONBLOCK ] 0 with
             | fd -> Some fd
             | exception Unix.Unix_error (Unix.ENOENT, _, _) -> None) with
           | Error error -> Private_file_failed error
           | Ok None ->
             (match on_missing () with
              | Ok value -> Private_file_succeeded value
              | Error error -> Private_file_failed error)
           | Ok (Some fd) ->
             private_jsonl_with_fd_outcome
               ~close_operation:Close_transaction_data
               ~close_fd:io.close_fd
               fd
               (fun () ->
                  let open Result.Syntax in
                  let* stats = capture Inspect_transaction_data (fun () -> Unix.fstat fd) in
                  match stats.Unix.st_kind with
                    | (Unix.S_DIR | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK
                      | Unix.S_FIFO | Unix.S_SOCK) as kind ->
                      Error (non_regular kind)
                    | Unix.S_REG ->
                      capture Read_transaction_data (fun () ->
                        lock_whole_file_shared fd;
                        read fd))))
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exception_ ->
    Private_file_failed
      (operation_failed (private_jsonl_failure Read_transaction_data exception_))
;;

let read_private_jsonl_locked_with_io ~io ~missing path read =
  read_private_jsonl_locked_with_errors ~io ~on_missing:(fun () -> Ok missing)
    ~non_regular:(fun kind -> Private_jsonl_rows.Non_regular_file kind)
    ~operation_failed:(fun failure -> Private_jsonl_rows.Io_failed failure.exception_)
    path read
;;

let read_private_jsonl_rows_locked_with_io ~io path =
  let open Private_jsonl_rows in
  read_private_jsonl_locked_with_io ~io ~missing:Rows_missing path (fun fd ->
    let bytes = read_fd_chunks fd in
    let end_offset = String.length bytes in
    let rows_end =
      match String.rindex_opt bytes '\n' with
      | Some newline -> newline + 1
      | None -> 0
    in
    Rows_present { rows = String.sub bytes 0 rows_end; rows_end; end_offset })
;;

let read_private_jsonl_rows_locked_result path =
  read_private_jsonl_rows_locked_with_io ~io:private_jsonl_transaction_unix_io path
;;

let read_private_jsonl_rows_locked_with_io_for_testing ~io path =
  read_private_jsonl_rows_locked_with_io ~io path
;;

module Private_jsonl_fold = struct
  type 'a t =
    | Missing
    | Present of { value : 'a; rows_end : int; end_offset : int }

  type error =
    | Read_error of Private_jsonl_rows.error
    | Snapshot_changed
end

let fold_private_jsonl_fd ~snapshot_changed ~validate_binding fd ~init ~f =
  let open Private_jsonl_fold in
  let open Result.Syntax in
  let before = Unix.fstat fd in
  let* () = validate_binding before in
  let buffer = Bytes.create 65536 and row = Buffer.create 256 in
  let value = ref init and end_offset = ref 0 and rows_end = ref 0 in
  let rec read () =
    let remaining = before.Unix.st_size - !end_offset in
    let length = if remaining <= 0 then 0
      else Unix.read fd buffer 0 (min remaining (Bytes.length buffer)) in
    if length > 0 then (
      let start = ref 0 in
      for index = 0 to length - 1 do
        if Bytes.get buffer index = '\n' then (
          Buffer.add_subbytes row buffer !start (index - !start);
          value := f !value (Buffer.contents row);
          Buffer.clear row;
          rows_end := !end_offset + index + 1;
          start := index + 1)
      done;
      Buffer.add_subbytes row buffer !start (length - !start);
      end_offset := !end_offset + length;
      read ()) in
  read ();
  let* () = validate_binding before in
  if not (same_file_snapshot before (Unix.fstat fd))
      || !end_offset <> before.Unix.st_size
  then Error snapshot_changed
  else Ok (Present {value= !value;rows_end= !rows_end;end_offset= !end_offset})
;;

let private_jsonl_fold_outcome ~read_error = function
  | Private_file_succeeded (Ok value) -> Private_file_succeeded value
  | Private_file_succeeded (Error error) -> Private_file_failed error
  | Private_file_succeeded_with_cleanup_failure {value=Ok value;cleanup_failure} ->
    Private_file_succeeded_with_cleanup_failure {value;cleanup_failure}
  | Private_file_succeeded_with_cleanup_failure {value=Error error;cleanup_failure} ->
    Private_file_failed_with_cleanup_failure {error;cleanup_failure}
  | Private_file_failed error -> Private_file_failed (read_error error)
  | Private_file_failed_with_cleanup_failure {error;cleanup_failure} ->
    Private_file_failed_with_cleanup_failure {error=read_error error;cleanup_failure}
;;

let fold_private_jsonl_locked_result path ~init ~f =
  let open Private_jsonl_fold in
  read_private_jsonl_locked_with_io
    ~io:private_jsonl_transaction_unix_io ~missing:(Ok Missing) path (fun fd ->
      let validate_binding before =
        match Unix.stat path with
        | current ->
          if same_file_snapshot before current then Ok () else Error Snapshot_changed
        | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Error Snapshot_changed in
      fold_private_jsonl_fd ~snapshot_changed:Snapshot_changed ~validate_binding fd ~init ~f)
  |> private_jsonl_fold_outcome ~read_error:(fun error -> Read_error error)
;;

module Private_jsonl_unique_fold = struct
  type error =
    | Non_regular_file of Unix.file_kind
    | Snapshot_changed
    | Binding_refused of private_jsonl_transaction_error
    | Operation_failed of private_jsonl_operation_failure

  let error_to_string = function
    | Non_regular_file kind ->
      "private JSONL store is not a regular file: " ^ file_kind_to_string kind
    | Snapshot_changed -> "private JSONL source changed during observation"
    | Binding_refused error -> private_jsonl_transaction_error_to_string error
    | Operation_failed failure -> private_jsonl_operation_failure_to_string failure
end

let fold_private_jsonl_unique_regular_locked_with_io ~io path ~init ~f =
  let open Private_jsonl_unique_fold in
  let on_missing () =
    match Private_jsonl_absence.check path with
    | Ok () -> Ok (Ok Private_jsonl_fold.Missing)
    | Error (Private_jsonl_absence.Binding_refused error) ->
      Ok (Error (Binding_refused error))
    | Error (Private_jsonl_absence.Operation_failed failure) ->
      Error (Operation_failed failure)
  in
  read_private_jsonl_locked_with_errors ~io ~on_missing
    ~non_regular:(fun kind -> Non_regular_file kind)
    ~operation_failed:(fun failure -> Operation_failed failure)
    path (fun fd ->
      let validate_binding before =
        let open Result.Syntax in
        let* path_stats, fd_stats =
          private_jsonl_capture Inspect_transaction_path (fun () -> Unix.lstat path, Unix.fstat fd)
          |> Result.map_error (fun failure -> Operation_failed failure) in
        let* () = private_jsonl_validate_unique_regular_binding ~path ~path_stats ~fd_stats
          |> Result.map_error (fun error -> Binding_refused error) in
        if same_file_snapshot before path_stats && same_file_snapshot before fd_stats
        then Ok () else Error Snapshot_changed
      in
      fold_private_jsonl_fd ~snapshot_changed:Snapshot_changed ~validate_binding fd ~init ~f)
  |> private_jsonl_fold_outcome ~read_error:Fun.id
;;

let fold_private_jsonl_unique_regular_locked_result path ~init ~f =
  fold_private_jsonl_unique_regular_locked_with_io
    ~io:private_jsonl_transaction_unix_io path ~init ~f
;;

let fold_private_jsonl_unique_regular_locked_with_io_for_testing ~io path ~init ~f =
  fold_private_jsonl_unique_regular_locked_with_io ~io path ~init ~f
;;

module Private_jsonl_window = struct
  type t =
    | Window_missing
    | Window_present of
        { previous_row : (int * string) option
        ; from_starts_row : bool
        ; rows : string
        ; window_end : int
        ; rows_end : int
        ; end_offset : int
        }
end

let private_jsonl_window_chunk_bytes = 65536

(* The rows framing of [read_private_jsonl_rows_locked_with_io], under the same
   lock, for a reader that needs only some rows: where the complete rows end,
   the row before [from], and at most [max_rows] rows from [from]. The ends are
   found by scanning back a chunk at a time, so a read costs the rows it
   returns and the ones it looks at, not the whole store. *)
let read_private_jsonl_window_locked_with_io
      ~io
      path
      ~from
      ~max_rows
      ~previous_row_wanted
  =
  if from < 0 then invalid_arg "read_private_jsonl_window_locked: negative offset";
  if max_rows < 1 then invalid_arg "read_private_jsonl_window_locked: max_rows below one";
  let open Private_jsonl_window in
  read_private_jsonl_locked_with_io ~io ~missing:Window_missing path (fun fd ->
    let chunk = Bytes.create private_jsonl_window_chunk_bytes in
    let read_at ~offset buffer ~length =
      (* See Unix.lseek: only the file-position side effect is required. *)
      ignore (Unix.lseek fd offset Unix.SEEK_SET : int);
      let rec fill filled =
        if filled < length
        then (
          match Unix.read fd buffer filled (length - filled) with
          | 0 -> raise End_of_file
          | count -> fill (filled + count)
          | exception Unix.Unix_error (Unix.EINTR, _, _) -> fill filled)
      in
      fill 0
    in
    (* The last '\n' in [[floor, until)]. *)
    let rec newline_before ~until ~floor =
      if until <= floor
      then None
      else (
        let start = Int.max floor (until - Bytes.length chunk) in
        let length = until - start in
        read_at ~offset:start chunk ~length;
        match Bytes.rindex_from_opt chunk (length - 1) '\n' with
        | Some index -> Some (start + index)
        | None -> newline_before ~until:start ~floor)
    in
    let end_offset = Unix.lseek fd 0 Unix.SEEK_END in
    let rows_end =
      match newline_before ~until:end_offset ~floor:0 with
      | Some newline -> newline + 1
      | None -> 0
    in
    let from_starts_row =
      from = 0
      || (from <= rows_end
          && (read_at ~offset:(from - 1) chunk ~length:1;
              Char.equal (Bytes.get chunk 0) '\n'))
    in
    if from > rows_end || not from_starts_row
    then
      Window_present
        { previous_row = None
        ; from_starts_row
        ; rows = ""
        ; window_end = from
        ; rows_end
        ; end_offset
        }
    else (
      (* The nearest row before [row_end] the caller wants, as its start and
         its bytes without the '\n'. *)
      let rec previous ~row_end =
        if row_end <= 0
        then None
        else (
          let row_start =
            match newline_before ~until:(row_end - 1) ~floor:0 with
            | Some newline -> newline + 1
            | None -> 0
          in
          let line = Bytes.create (row_end - 1 - row_start) in
          read_at ~offset:row_start line ~length:(Bytes.length line);
          let line = Bytes.unsafe_to_string line in
          if previous_row_wanted line
          then Some (row_start, line)
          else previous ~row_end:row_start)
      in
      let previous_row = previous ~row_end:from in
      let buffer = Buffer.create (Int.min (rows_end - from + 1) (Bytes.length chunk)) in
      let rec forward ~offset ~rows =
        if rows >= max_rows || offset >= rows_end
        then offset
        else (
          let length = Int.min (Bytes.length chunk) (rows_end - offset) in
          read_at ~offset chunk ~length;
          let rec take index rows =
            if rows >= max_rows || index >= length
            then index, rows
            else (
              match Bytes.index_from_opt chunk index '\n' with
              | Some newline when newline < length -> take (newline + 1) (rows + 1)
              | Some _ | None -> length, rows)
          in
          let used, rows = take 0 rows in
          Buffer.add_subbytes buffer chunk 0 used;
          forward ~offset:(offset + used) ~rows)
      in
      let window_end = forward ~offset:from ~rows:0 in
      Window_present
        { previous_row
        ; from_starts_row
        ; rows = Buffer.contents buffer
        ; window_end
        ; rows_end
        ; end_offset
        }))
;;

let read_private_jsonl_window_locked_result path ~from ~max_rows ~previous_row_wanted =
  read_private_jsonl_window_locked_with_io
    ~io:private_jsonl_transaction_unix_io
    path
    ~from
    ~max_rows
    ~previous_row_wanted
;;

module Private_jsonl_tail = struct
  type t =
    | Tail_missing
    | Tail_present of
        { rows : string
        ; prefix_omitted : bool
        ; incomplete_tail : bool
        ; end_offset : int
        }

  type error =
    | Invalid_max_bytes of int
    | Read_error of Private_jsonl_rows.error

  let error_to_string = function
    | Invalid_max_bytes bytes ->
      Printf.sprintf "private JSONL tail byte limit must be positive: %d" bytes
    | Read_error error -> Private_jsonl_rows.error_to_string error
  ;;
end

let read_private_jsonl_tail_locked_result path ~max_bytes =
  let open Private_jsonl_tail in
  if max_bytes <= 0
  then Private_file_failed (Invalid_max_bytes max_bytes)
  else
    let read fd =
      let end_offset = Unix.lseek fd 0 Unix.SEEK_END in
      let from = max 0 (end_offset - max_bytes) in
      let starts_at_row =
        from = 0 || Char.equal (private_jsonl_read_byte fd (Bytes.create 1) (from - 1)) '\n'
      in
      let length = end_offset - from in
      let bytes = Bytes.create length in
      ignore (Unix.lseek fd from Unix.SEEK_SET : int);
      let rec read_all offset =
        if offset < length then
          match Unix.read fd bytes offset (length - offset) with
          | 0 -> raise End_of_file
          | count -> read_all (offset + count)
          | exception Unix.Unix_error (Unix.EINTR, _, _) -> read_all offset
      in
      read_all 0;
      let bytes = Bytes.unsafe_to_string bytes in
      let rows_start =
        if starts_at_row then 0
        else match String.index_opt bytes '\n' with
          | Some newline -> newline + 1
          | None -> length
      in
      let rows_end =
        match String.rindex_opt bytes '\n' with
        | Some newline -> newline + 1
        | None -> 0
      in
      Tail_present
        { rows = String.sub bytes rows_start (max 0 (rows_end - rows_start))
        ; prefix_omitted = from > 0
        ; incomplete_tail = length > 0 && not (Char.equal bytes.[length - 1] '\n')
        ; end_offset
        }
    in
    match read_private_jsonl_locked_with_io ~io:private_jsonl_transaction_unix_io
            ~missing:Tail_missing path read with
    | Private_file_succeeded value -> Private_file_succeeded value
    | Private_file_succeeded_with_cleanup_failure { value; cleanup_failure } ->
      Private_file_succeeded_with_cleanup_failure { value; cleanup_failure }
    | Private_file_failed error -> Private_file_failed (Read_error error)
    | Private_file_failed_with_cleanup_failure { error; cleanup_failure } ->
      Private_file_failed_with_cleanup_failure { error = Read_error error; cleanup_failure }
;;

type 'a private_jsonl_recovery_validation =
  | Recovery_authorized
  | Recovery_refused of 'a

type 'a private_jsonl_recovered =
  | Recovered_prefix of string
  | Recovery_result of 'a

type private_file_locking = Wait_for_lock | Try_lock

let with_private_path_lock ~locking ~path mutex f =
  match locking with
  | Wait_for_lock -> Stdlib.Mutex.protect mutex f
  | Try_lock ->
    if not (Stdlib.Mutex.try_lock mutex) then
      raise (Sys_error ("private file is busy: " ^ path));
    Fun.protect ~finally:(fun () -> Stdlib.Mutex.unlock mutex) f

let update_private_file_durable_locked_with_io ?(create=true) ?(locking=Wait_for_lock) ?validate_prefix ?tail_bytes
    ?(confirm_existing=(fun () -> false)) ?(verify_content=false)
    ?(append_io=durable_append_unix_io) ~io path decide =
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
           let from =
             match tail_bytes with
             | None -> 0
             | Some max_bytes ->
               Int.max 0 ((Unix.fstat fd).Unix.st_size - max_bytes)
           in
           let starts_at_row =
             from = 0
             || Char.equal (private_jsonl_read_byte fd (Bytes.create 1) (from - 1)) '\n'
           in
           ignore (Unix.lseek fd from Unix.SEEK_SET : int);
           let before_read = Unix.fstat fd in
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
              let original_length = Unix.lseek fd 0 Unix.SEEK_END in
              append_fd_durable
                ~io:append_io
                ~fd
                ~original_length
                suffix
              |> Result.map (fun () ->
                validate_binding ();
                if verify_content then verify_bytes (existing ^ suffix);
                result)))))
;;

type 'a private_file_decision =
  | Refuse_update of 'a
  | Confirm_existing of 'a
  | Append_confirmed of string * 'a

let reconcile_private_file_durable_locked_with_append_io ~locking ~append_io path decide =
  let confirmation = ref false in
  update_private_file_durable_locked_with_io ~locking
    ~verify_content:true ~confirm_existing:(fun () -> !confirmation) ~append_io
    ~io:private_jsonl_transaction_unix_io path (fun existing ->
      match decide existing with
      | Refuse_update result -> None,result
      | Confirm_existing result -> confirmation := true; None,result
      | Append_confirmed (suffix,result) -> Some suffix,result)
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
    decide
;;

let update_private_file_tail_durable_locked_result path ~max_bytes decide =
  if max_bytes <= 0 then invalid_arg "update_private_file_tail_durable_locked_result";
  update_private_file_durable_locked_with_io ~tail_bytes:max_bytes
    ~io:private_jsonl_transaction_unix_io path decide
;;

let update_private_file_tail_durable_locked_with_append_io_for_testing
    ~append_io path ~max_bytes decide =
  if max_bytes <= 0 then invalid_arg "update_private_file_tail_durable_locked_result";
  update_private_file_durable_locked_with_io ~tail_bytes:max_bytes ~append_io
    ~io:private_jsonl_transaction_unix_io path decide
;;

let recover_and_update_private_jsonl_durable_locked_result ?(create=true) ?(locking=Wait_for_lock) ~validate_prefix path decide =
  update_private_file_durable_locked_with_io ~create ~locking ~validate_prefix
    ~io:private_jsonl_transaction_unix_io path decide
;;

let update_private_file_durable_locked_with_io_for_testing ?(create=true) ~io path decide =
  update_private_file_durable_locked_with_io ~create ~io path decide
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
   dies part way through it, so it is never a row. The caller holds the path
   mutex, which the other appenders here also take ([append_file],
   [append_jsonl], [update_private_file_durable_locked_result]), and the
   exclusive [lockf], which every durable writer in another process takes. No
   such writer is in the file while it is cut back to the last '\n' and
   fsynced; a writer in another process that takes neither lock is not
   excluded. Returns the length the append then starts from. *)
let truncate_incomplete_jsonl_tail ~path ~fd ~end_offset =
  let read_rows_end () =
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
  in
  Result.bind (read_rows_end ()) (fun rows_end ->
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
           (run_unix_io ~operation:Incomplete_tail_fsync (fun () -> Unix.fsync fd))))
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
                  match expected_end_offset with
                  | Some expected when expected <> original_length ->
                    Error
                      (End_offset_mismatch
                         { expected; actual = original_length })
                  | _ ->
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
                    (* An offset-checked caller conditioned its write on the
                       length it observed, fragment included, so only an
                       append without that condition cuts the fragment. *)
                    let append_from =
                      if tail_is_complete
                      then Ok original_length
                      else (
                        match expected_end_offset with
                        | Some _ -> Error Incomplete_jsonl_tail
                        | None ->
                          truncate_incomplete_jsonl_tail
                            ~path
                            ~fd
                            ~end_offset:original_length
                          |> Result.map_error (fun failure ->
                            Incomplete_jsonl_tail_truncate_failed failure))
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
    Eio_unix.run_in_systhread
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
      Eio_unix.run_in_systhread
        ~label:(labelled "fs-compat-append-jsonl-batch" path) write
  end
;;
