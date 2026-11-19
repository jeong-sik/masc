module Log = Librarian_log
module Codec = Librarian_log_codec

let suffix = ".memory-log.jsonl"

let path_for_keepers_dir ~keepers_dir ~keeper_id =
  Filename.concat keepers_dir (keeper_id ^ suffix)
;;

type tail =
  | Nothing_written
  | Written of
      { rows_end : int
      ; last_at : int
      ; last : Log.line
      }

type undecodable =
  | Not_json
  | Malformed of Keeper_memory_os_types.wire_error

type read_error =
  | Read_failed of
      { path : string
      ; detail : string
      }
  | Tail_undecodable of
      { offset : int
      ; rows_end : int
      ; reason : undecodable
      }
  | Moved_while_reading

let decode row =
  match Yojson.Safe.from_string row with
  | exception Yojson.Json_error (_ : string) -> Error Not_json
  | json -> Result.map_error (fun error -> Malformed error) (Codec.of_json json)
;;

(* The error is the reader's own text for why the file was not read. *)
let window path ~from ~max_rows ~previous_row_wanted =
  match
    Fs_compat.read_private_jsonl_window_locked_result path ~from ~max_rows ~previous_row_wanted
  with
  | Fs_compat.Private_file_succeeded window
  | Fs_compat.Private_file_succeeded_with_cleanup_failure { value = window; _ } -> Ok window
  | Fs_compat.Private_file_failed error
  | Fs_compat.Private_file_failed_with_cleanup_failure { error; _ } ->
    Error (Fs_compat.Private_jsonl_rows.error_to_string error)
;;

let no_row_before (_ : string) = false

(* Two locked reads: where the lines end, then the line before that end. *)
let read_tail path =
  let ( let* ) = Result.bind in
  let window ~from ~previous_row_wanted =
    Result.map_error
      (fun detail -> Read_failed { path; detail })
      (window path ~from ~max_rows:1 ~previous_row_wanted)
  in
  let* first = window ~from:0 ~previous_row_wanted:no_row_before in
  match first with
  | Fs_compat.Private_jsonl_window.Window_missing -> Ok Nothing_written
  | Window_present { rows_end = 0; _ } -> Ok Nothing_written
  | Window_present { rows_end; _ } ->
    let* second = window ~from:rows_end ~previous_row_wanted:(fun (_ : string) -> true) in
    (match second with
     | Window_missing -> Ok Nothing_written
     | Window_present { from_starts_row = false; _ }
     | Window_present { from_starts_row = true; previous_row = None; _ } ->
       Error Moved_while_reading
     | Window_present { from_starts_row = true; previous_row = Some (offset, row); _ } ->
       (* The reader says where the line before the end starts. It has to end
          where the first read said the lines end. *)
       if not (Int.equal (offset + String.length row + 1) rows_end)
       then Error Moved_while_reading
       else (
         match decode row with
         | Ok last -> Ok (Written { rows_end; last_at = offset; last })
         | Error reason -> Error (Tail_undecodable { offset; rows_end; reason })))
;;

type scan_error =
  | Scan_read_failed of
      { path : string
      ; detail : string
      }
  | Scan_moved

type scanned =
  { at : int
  ; line : (Log.line, undecodable) result
  }

(* A line is 8 to 10 KB (RFC §10), so one locked read holds well under a
   megabyte. *)
let scan_window_rows = 64

let fold_rows ~f acc ~from rows =
  let rec next acc start =
    match String.index_from_opt rows start '\n' with
    | None -> acc
    | Some stop ->
      let row = String.sub rows start (stop - start) in
      next (f acc { at = from + start; line = decode row }) (stop + 1)
  in
  next acc 0
;;

let fold path ~init ~f =
  let rec from_offset acc from =
    match window path ~from ~max_rows:scan_window_rows ~previous_row_wanted:no_row_before with
    | Error detail -> Error (Scan_read_failed { path; detail })
    | Ok Fs_compat.Private_jsonl_window.Window_missing -> Ok acc
    | Ok (Window_present { from_starts_row = false; _ }) -> Error Scan_moved
    | Ok (Window_present { from_starts_row = true; rows; window_end; _ }) ->
      if String.equal rows ""
      then Ok acc
      else from_offset (fold_rows ~f acc ~from rows) window_end
  in
  from_offset init 0
;;

type append_error =
  | End_moved of
      { expected : int
      ; actual : int
      }
  | Directory_unavailable of
      { path : string
      ; detail : string
      }
  | Write_failed of
      { path : string
      ; detail : string
      }

type appended =
  { new_end : int
  ; at : int
  }

let append ~path ~at_end line =
  let row = Yojson.Safe.to_string (Codec.to_json line) ^ "\n" in
  let dir = Filename.dirname path in
  (* The offset-checked append does not create its directory. *)
  match Fs_compat.mkdir_p dir with
  | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
  | exception exn -> Error (Directory_unavailable { path = dir; detail = Printexc.to_string exn })
  | () ->
    (match
       Fs_compat.append_private_jsonl_durable_locked_at_end_offset_result path
         ~expected_end_offset:at_end row
     with
     (* The line is on disk. A cleanup failure is about the descriptor, and
        calling it a write failure would invite a second append. *)
     | Fs_compat.Private_file_succeeded new_end
     | Fs_compat.Private_file_succeeded_with_cleanup_failure { value = new_end; _ } ->
       Ok { new_end; at = new_end - String.length row }
     | Fs_compat.Private_file_failed (Fs_compat.End_offset_mismatch { expected; actual })
     | Fs_compat.Private_file_failed_with_cleanup_failure
         { error = Fs_compat.End_offset_mismatch { expected; actual }; _ } ->
       Error (End_moved { expected; actual })
     (* The helper says this when the offset it was given is the file's
        length and the file ends in a fragment. The tail that was read ended
        at a line break, so the file is not the one that was read. *)
     | Fs_compat.Private_file_failed Fs_compat.Incomplete_jsonl_tail
     | Fs_compat.Private_file_failed_with_cleanup_failure
         { error = Fs_compat.Incomplete_jsonl_tail; _ } ->
       Error (End_moved { expected = at_end; actual = at_end })
     | Fs_compat.Private_file_failed
         (( Fs_compat.Incomplete_jsonl_tail_truncate_failed _
          | Fs_compat.Existing_jsonl_refused _
          | Fs_compat.Invalid_jsonl_suffix
          | Fs_compat.Negative_expected_end_offset _
          | Fs_compat.Durable_jsonl_append_failed _ ) as error)
     | Fs_compat.Private_file_failed_with_cleanup_failure
         { error =
             ( Fs_compat.Incomplete_jsonl_tail_truncate_failed _
             | Fs_compat.Existing_jsonl_refused _
             | Fs_compat.Invalid_jsonl_suffix
             | Fs_compat.Negative_expected_end_offset _
             | Fs_compat.Durable_jsonl_append_failed _ ) as error
         ; _
         } ->
       Error (Write_failed { path; detail = Fs_compat.private_jsonl_append_error_to_string error }))
;;
