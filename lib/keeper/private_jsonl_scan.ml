type error =
  | Read_failed of
      { path : string
      ; detail : string
      }
  | Moved

let error_to_string = function
  | Read_failed { path; detail } -> Printf.sprintf "%s was not read: %s" path detail
  | Moved -> "the file was cut, replaced or removed while it was being read"
;;

let window path ~from ~rows_per_read =
  match
    Fs_compat.read_private_jsonl_window_locked_result path ~from ~max_rows:rows_per_read
      ~previous_row_wanted:No_previous_row
  with
  | Fs_compat.Private_file_failed error
  | Fs_compat.Private_file_failed_with_cleanup_failure { error; _ } ->
    Error (Read_failed { path; detail = Fs_compat.Private_jsonl_rows.error_to_string error })
  | Fs_compat.Private_file_succeeded window
  | Fs_compat.Private_file_succeeded_with_cleanup_failure { value = window; _ } -> Ok window
;;

type ('acc, 'stop) step =
  | Continue of 'acc
  | Stop of 'stop

type ('acc, 'stop) folded =
  | Reached_end of 'acc
  | Stopped of 'stop

type from_error =
  | Not_a_row_start of
      { from : int
      ; length : int
      }
  | Scan_failed of error

(* The rows of one window until [f] stops. [Continue] carries what the
   window leaves for the next one. *)
let rows_until_stop ~f acc ~from rows =
  let rec next acc start =
    match String.index_from_opt rows start '\n' with
    | None -> Continue acc
    | Some stop ->
      (match f acc ~at:(from + start) (String.sub rows start (stop - start)) with
       | Continue acc -> next acc (stop + 1)
       | Stop stopped -> Stop stopped)
  in
  next acc 0
;;

let fold_from path ~from ~rows_per_read ~init ~f =
  let rec through acc ~from ~rows ~window_end =
    if String.equal rows ""
    then Ok (Reached_end acc)
    else (
      match rows_until_stop ~f acc ~from rows with
      | Stop stopped -> Ok (Stopped stopped)
      | Continue acc ->
        (match window path ~from:window_end ~rows_per_read with
         | Error error -> Error (Scan_failed error)
         (* The row the last window ended at is gone. *)
         | Ok (Fs_compat.Private_jsonl_window.Window_missing | Window_present { from_starts_row = false; _ })
           -> Error (Scan_failed Moved)
         | Ok (Window_present { from_starts_row = true; rows; window_end = next_end; _ }) ->
           through acc ~from:window_end ~rows ~window_end:next_end))
  in
  match window path ~from ~rows_per_read with
  | Error error -> Error (Scan_failed error)
  | Ok Fs_compat.Private_jsonl_window.Window_missing ->
    if Int.equal from 0 then Ok (Reached_end init) else Error (Not_a_row_start { from; length = 0 })
  | Ok (Window_present { from_starts_row = false; end_offset; _ }) ->
    Error (Not_a_row_start { from; length = end_offset })
  | Ok (Window_present { from_starts_row = true; rows; window_end; _ }) ->
    through init ~from ~rows ~window_end
;;

(* A whole-file scan never stops early, so its stop value has no case. *)
type never = |

(* One loop reads every scan. A file that goes away after the first read is
   [Moved] here too, not a scan that ended. *)
let fold path ~rows_per_read ~init ~f =
  match
    fold_from path ~from:0 ~rows_per_read ~init ~f:(fun acc ~at row ->
      (Continue (f acc ~at row) : (_, never) step))
  with
  | Ok (Reached_end acc) -> Ok acc
  | Ok (Stopped _) -> .
  | Error (Scan_failed error) -> Error error
  (* Offset 0 starts a row in any file, so the first read saw the file
     change under it. *)
  | Error (Not_a_row_start { from = (_ : int); length = (_ : int) }) -> Error Moved
;;
