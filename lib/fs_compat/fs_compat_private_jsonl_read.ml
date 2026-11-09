open Fs_compat_base_io
open Fs_compat_owned_file
open Fs_compat_jsonl_read
open Fs_compat_durable_append
open Fs_compat_private_jsonl_transaction
open Fs_compat_private_jsonl_write

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
