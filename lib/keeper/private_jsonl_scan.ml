type error =
  | Read_failed of
      { path : string
      ; detail : string
      }
  | Moved

let error_to_string = function
  | Read_failed { path; detail } -> Printf.sprintf "%s was not read: %s" path detail
  | Moved -> "the file was cut or replaced while it was being read"
;;

let fold_rows ~f acc ~from rows =
  let rec next acc start =
    match String.index_from_opt rows start '\n' with
    | None -> acc
    | Some stop -> next (f acc ~at:(from + start) (String.sub rows start (stop - start))) (stop + 1)
  in
  next acc 0
;;

let fold path ~rows_per_read ~init ~f =
  let rec from_offset acc from =
    match
      Fs_compat.read_private_jsonl_window_locked_result path ~from ~max_rows:rows_per_read
        ~previous_row_wanted:No_previous_row
    with
    | Fs_compat.Private_file_failed error
    | Fs_compat.Private_file_failed_with_cleanup_failure { error; _ } ->
      Error (Read_failed { path; detail = Fs_compat.Private_jsonl_rows.error_to_string error })
    | Fs_compat.Private_file_succeeded window
    | Fs_compat.Private_file_succeeded_with_cleanup_failure { value = window; _ } ->
      (match window with
       | Fs_compat.Private_jsonl_window.Window_missing -> Ok acc
       | Window_present { from_starts_row = false; _ } -> Error Moved
       | Window_present { from_starts_row = true; rows; window_end; _ } ->
         if String.equal rows ""
         then Ok acc
         else from_offset (fold_rows ~f acc ~from rows) window_end)
  in
  from_offset init 0
;;
