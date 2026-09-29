(* See candle_ledger.mli. *)

let file_name = "candle-ledger.jsonl"

let path ~base_path =
  Filename.concat
    (Workspace_utils_paths_backend.masc_dir_from_base_path ~base_path)
    file_name
;;

type view =
  { events : Candle_event.t list
  ; cursor : Fs_compat.Private_jsonl_cursor.t
  }

let events view = view.events

type read_error =
  | Store_failed of
      { path : string
      ; detail : string
      }
  | Row_rejected of
      { path : string
      ; line_number : int
      ; detail : string
      }

let read_error_to_string = function
  | Store_failed { path; detail } ->
    Printf.sprintf "candle ledger %s could not be read: %s" path detail
  | Row_rejected { path; line_number; detail } ->
    Printf.sprintf "candle ledger %s row %d does not read: %s" path line_number detail
;;

type 'error update_error =
  | Read_failed of read_error
  | Refused of 'error
  | Event_unwritable of string
  | Write_failed of
      { path : string
      ; detail : string
      }

let update_error_to_string refusal_to_string = function
  | Read_failed error -> read_error_to_string error
  | Refused error -> refusal_to_string error
  | Event_unwritable detail ->
    Printf.sprintf "candle ledger event would not read back: %s" detail
  | Write_failed { path; detail } ->
    Printf.sprintf "candle ledger %s could not be written: %s" path detail
;;

(* The blocking file work runs in a system thread when there is an Eio fiber to
   keep unblocked, and inline when the caller is not under Eio. *)
let run_blocking label operation =
  match Eio.Fiber.is_cancelled () with
  | true | false -> Eio_unix.run_in_systhread ~label operation
  | exception Effect.Unhandled _ -> operation ()
;;

let store_error = Fs_compat.private_jsonl_transaction_error_to_string

(* True for the two failures that mean another writer was in the way: it holds
   the lock, or it appended after the position that was read. Every other
   failure is named here so that a new one in [Fs_compat] fails to compile until
   it is placed. *)
let another_writer_was_first : Fs_compat.private_jsonl_transaction_error -> bool = function
  | Fs_compat.Stable_lock_contended _ | Fs_compat.Cursor_mismatch _ -> true
  | Fs_compat.Unexpected_stable_lock_permissions _
  | Fs_compat.Invalid_stable_lock_state _
  | Fs_compat.Unexpected_transaction_file_kind _
  | Fs_compat.Ambiguous_transaction_file_identity _
  | Fs_compat.Transaction_path_binding_changed _
  | Fs_compat.Incomplete_transaction_tail _
  | Fs_compat.Invalid_transaction_suffix
  | Fs_compat.Private_jsonl_operation_failed _
  | Fs_compat.Rewrite_stage_failed _
  | Fs_compat.Rewrite_published_durability_unknown _
  | Fs_compat.Transaction_settlement_failed _
  | Fs_compat.Transaction_append_failed _ -> false
;;

let observe_settlement ~path error =
  Log.Misc.warn
    "candle ledger: descriptor settlement incomplete path=%s detail=%s"
    path
    (store_error error)
;;

(* A row is one JSON line. A complete store ends with a newline, so the piece
   after the last one is empty. *)
let parse_rows ~path bytes =
  let rec go line_number acc = function
    | [] | [ "" ] -> Ok (List.rev acc)
    | line :: rest ->
      (match Candle_event.of_line line with
       | Ok event -> go (line_number + 1) (event :: acc) rest
       | Error detail -> Error (Row_rejected { path; line_number; detail }))
  in
  go 1 [] (String.split_on_char '\n' bytes)
;;

type snapshot_outcome =
  | Snapshot_read of Fs_compat.private_jsonl_snapshot
  | Another_writer_held_it
  | Snapshot_failed of string

let snapshot_outcome ~path result =
  match Fs_compat.private_jsonl_snapshot_success_receipt result with
  | Error error ->
    if another_writer_was_first error
    then Another_writer_held_it
    else Snapshot_failed (store_error error)
  | Ok { Fs_compat.value; settlement_error } ->
    Option.iter (observe_settlement ~path) settlement_error;
    Snapshot_read value
;;

let view_of_snapshot ~path (snapshot : Fs_compat.private_jsonl_snapshot) =
  Result.map
    (fun events -> { events; cursor = snapshot.cursor })
    (parse_rows ~path snapshot.bytes)
;;

let view_of_outcome ~path = function
  | Snapshot_read snapshot -> view_of_snapshot ~path snapshot
  | Another_writer_held_it ->
    Error (Store_failed { path; detail = "another writer holds the ledger lock" })
  | Snapshot_failed detail -> Error (Store_failed { path; detail })
;;

let read_outcome ~path =
  run_blocking "candle-ledger-read" (fun () ->
    snapshot_outcome
      ~path
      (Fs_compat.read_private_jsonl_durable_locked_result path ~after:None))
;;

let read ~base_path =
  let path = path ~base_path in
  view_of_outcome ~path (read_outcome ~path)
;;

let recover_at_start ~base_path =
  let path = path ~base_path in
  view_of_outcome
    ~path
    (run_blocking "candle-ledger-recover" (fun () ->
       snapshot_outcome ~path (Fs_compat.recover_private_jsonl_durable_locked_result path)))
;;

type append_outcome =
  | Appended
  | Appended_after_another_writer
  | Append_failed of string

let append ~path cursor suffix =
  run_blocking "candle-ledger-append" (fun () ->
    match
      Fs_compat.private_jsonl_cursor_success_receipt
        (Fs_compat.append_private_jsonl_durable_locked_at_cursor_result
           path
           ~expected:cursor
           suffix)
    with
    | Ok { Fs_compat.value = _; settlement_error } ->
      Option.iter (observe_settlement ~path) settlement_error;
      Appended
    | Error error ->
      if another_writer_was_first error
      then Appended_after_another_writer
      else Append_failed (store_error error))
;;

let encode events =
  List.fold_left
    (fun acc event ->
       Result.bind acc (fun lines ->
         Result.map (fun line -> line :: lines) (Candle_event.to_line event)))
    (Ok [])
    events
  |> Result.map (fun lines ->
    String.concat "" (List.rev_map (fun line -> line ^ "\n") lines))
;;

let rec update ~base_path decide =
  let path = path ~base_path in
  match read_outcome ~path with
  | Another_writer_held_it -> update ~base_path decide
  | (Snapshot_read _ | Snapshot_failed _) as outcome ->
    (match view_of_outcome ~path outcome with
     | Error error -> Error (Read_failed error)
     | Ok view ->
       (match decide view with
        | Error error -> Error (Refused error)
        | Ok ([], result) -> Ok result
        | Ok ((_ :: _ as events), result) ->
          (match encode events with
           | Error detail -> Error (Event_unwritable detail)
           | Ok suffix ->
             (match append ~path view.cursor suffix with
              | Appended -> Ok result
              | Appended_after_another_writer -> update ~base_path decide
              | Append_failed detail -> Error (Write_failed { path; detail })))))
;;
