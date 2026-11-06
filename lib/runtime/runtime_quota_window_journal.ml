(* Provider-stated quota windows kept across server restarts. See the [.mli]. *)

module Q = Runtime_quota_window

let filename = "provider-quota-windows.jsonl"
let path ~base_path = Filename.concat (Common.masc_dir_from_base_path ~base_path) filename

type row_error =
  | Not_json of
      { line : int
      ; message : string
      }
  | Malformed of
      { line : int
      ; error : Q.stated_window_decode_error
      }
  | Incomplete_tail of { line : int }

let row_error_to_string = function
  | Not_json { line; message } -> Printf.sprintf "line %d is not JSON: %s" line message
  | Malformed { line; error } ->
    Printf.sprintf "line %d: %s" line (Q.stated_window_decode_error_to_string error)
  | Incomplete_tail { line } ->
    Printf.sprintf "line %d has no newline: an append never completed" line

type restore_report =
  { ahead : int
  ; passed : int
  ; rejected : row_error list
  }

type restore_error =
  | Store_unreadable of
      { path : string
      ; detail : string
      }

let restore_error_to_string (Store_unreadable { path; detail }) =
  Printf.sprintf "provider quota window store unreadable path=%s: %s" path detail

let settlement_failed ~path ~operation failure =
  Log.Runtime.warn "provider quota window %s; descriptor settlement failed path=%s: %s"
    operation path (Fs_compat.private_jsonl_operation_failure_to_string failure)

let append ~path (window : Q.stated_window) =
  let line = Yojson.Safe.to_string (Q.stated_window_to_json window) ^ "\n" in
  let failed detail =
    Log.Runtime.warn
      "provider quota window for %s until %.0f is not kept across restarts: path=%s: %s"
      (Q.scope_to_string window.scope) window.resets_at path detail
  in
  match Fs_compat.append_private_jsonl_durable_locked_result path line with
  | Fs_compat.Private_file_succeeded () -> ()
  | Fs_compat.Private_file_succeeded_with_cleanup_failure { value = (); cleanup_failure } ->
    settlement_failed ~path ~operation:"append committed" cleanup_failure
  | Fs_compat.Private_file_failed error ->
    failed (Fs_compat.private_jsonl_append_error_to_string error)
  | Fs_compat.Private_file_failed_with_cleanup_failure { error; cleanup_failure } ->
    failed
      (Printf.sprintf "%s; descriptor settlement also failed: %s"
         (Fs_compat.private_jsonl_append_error_to_string error)
         (Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure))
  | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
  | exception Sys_error message -> failed message
  | exception Unix.Unix_error (code, fn, arg) ->
    failed (Printf.sprintf "%s(%s): %s" fn arg (Unix.error_message code))

let decode_line ~line text =
  match Yojson.Safe.from_string text with
  | json ->
    Result.map_error (fun error -> Malformed { line; error }) (Q.stated_window_of_json json)
  | exception Yojson.Json_error message -> Error (Not_json { line; message })

(* [rows] is every newline-terminated row, so what follows its last newline is
   the empty string and not a row. *)
let decode_rows = function
  | Fs_compat.Private_jsonl_rows.Rows_missing -> []
  | Fs_compat.Private_jsonl_rows.Rows_present { rows; rows_end; end_offset } ->
    let complete =
      match List.rev (String.split_on_char '\n' rows) with
      | [] -> []
      | _after_last_newline :: reversed -> List.rev reversed
    in
    let decoded = List.mapi (fun index text -> decode_line ~line:(index + 1) text) complete in
    if rows_end < end_offset
    then decoded @ [ Error (Incomplete_tail { line = List.length complete + 1 }) ]
    else decoded

let read ~path =
  let unreadable error =
    Error (Store_unreadable { path; detail = Fs_compat.Private_jsonl_rows.error_to_string error })
  in
  match Fs_compat.read_private_jsonl_rows_locked_result path with
  | Fs_compat.Private_file_succeeded rows -> Ok (decode_rows rows)
  | Fs_compat.Private_file_succeeded_with_cleanup_failure { value; cleanup_failure } ->
    settlement_failed ~path ~operation:"read" cleanup_failure;
    Ok (decode_rows value)
  | Fs_compat.Private_file_failed error -> unreadable error
  | Fs_compat.Private_file_failed_with_cleanup_failure { error; cleanup_failure } ->
    settlement_failed ~path ~operation:"read failed" cleanup_failure;
    unreadable error

let restore ~now rows =
  List.fold_left
    (fun report row ->
       match row with
       | Error error -> { report with rejected = error :: report.rejected }
       | Ok ({ Q.scope; resets_at } : Q.stated_window) ->
         if Float.compare now resets_at < 0
         then (
           Q.note_exhausted ~scope ~resets_at;
           { report with ahead = report.ahead + 1 })
         else { report with passed = report.passed + 1 })
    { ahead = 0; passed = 0; rejected = [] }
    rows
  |> fun report -> { report with rejected = List.rev report.rejected }

(* The restored windows are noted with no sink installed, so the rows they came
   from are not appended a second time. *)
let restore_then_record ~base_path ~now =
  let path = path ~base_path in
  Q.set_stated_window_sink ignore;
  let restored = Result.map (restore ~now) (read ~path) in
  Q.set_stated_window_sink (append ~path);
  restored
