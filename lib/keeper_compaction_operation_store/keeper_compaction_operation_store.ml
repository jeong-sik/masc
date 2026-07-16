module Operation = Keeper_compaction_operation
module Reducer = Keeper_compaction_operation_reducer
module Event = Keeper_operation_event
module Record = Keeper_operation_record
module Cursor = Record.Cursor
module Projection = Keeper_compaction_operation_projection
type row = Record.row
type operation_entry = Projection.operation_entry =
  { snapshot : Reducer.snapshot
  ; requested_at : float
  ; request_cursor : Cursor.t
  }
type replay = { operations : operation_entry list; end_cursor : Cursor.t }
type slice = { rows : row list; end_cursor : Cursor.t }
type t =
  { path : string
  ; projection : Projection.t
  }
type event_rejection = Projection.rejection =
  | Cursor_mismatch of
      { expected : Cursor.t
      ; actual : Cursor.t
      }
  | Transition_rejected of Reducer.transition_error
  | Keeper_mismatch of
      { expected : Keeper_id.Keeper_name.t
      ; actual : Keeper_id.Keeper_name.t
      }
  | Producer_already_bound of
      { producer : Operation.producer_ref
      ; existing_operation_id : Operation.Operation_id.t
      }
type history_error =
  | Invalid_record of Record.decode_error
  | Rejected_row of
      { row_number : int
      ; start_cursor : Cursor.t
      ; end_cursor : Cursor.t
      ; rejection : event_rejection
      }
type read_error =
  | Read_failed of Fs_compat.Private_jsonl_slice.error
  | Invalid_history of history_error
type transaction_error =
  | Cursor_conflict of
      { expected : Cursor.t
      ; actual : Cursor.t
      }
  | Committed_cursor_mismatch of
      { expected : Cursor.t
      ; actual : Cursor.t
      }
  | Not_committed of Fs_compat.durable_append_error
  | Outcome_unknown of Fs_compat.durable_append_error
  | Storage_rejected of Fs_compat.private_jsonl_append_error
  | Access_failed of exn
type append_error =
  | Encode_failed of Record.envelope_error
  | Event_rejected of event_rejection
  | Transaction_error of transaction_error
let cursor value =
  match Cursor.of_int value with
  | Ok cursor -> cursor
  | Error _ -> invalid_arg "negative durable journal offset"
;;
let journal_path ~base_path ~keeper_name =
  Filename.concat
    (Filename.concat
       (Common.keepers_runtime_dir_of_base ~base_path)
       (Keeper_id.Keeper_name.to_string keeper_name))
    "operation-journal.jsonl"
;;
let decode_history ~keeper_name bytes =
  match Record.decode_rows ~from:Cursor.zero ~row_number:(Some 1) bytes with
  | Error error -> Error (Invalid_record error)
  | Ok rows ->
    Projection.replay ~keeper_name rows
    |> Result.map_error (function
      | Projection.Rejected_row
          { row_number; start_cursor; end_cursor; rejection } ->
        Rejected_row { row_number; start_cursor; end_cursor; rejection })
    |> Result.map (fun state -> rows, state)
;;
let open_writer ~base_path ~keeper_name =
  let path = journal_path ~base_path ~keeper_name in
  match Fs_compat.read_private_jsonl_slice_locked_result path ~from:0 with
  | Error error -> Error (Read_failed error)
  | Ok source ->
    (match decode_history ~keeper_name source.bytes with
     | Error error -> Error (Invalid_history error)
     | Ok (_, projection) -> Ok { path; projection })
;;
let operations writer = Projection.operations writer.projection
let end_cursor writer = Projection.end_cursor writer.projection
let replay ~base_path ~keeper_name =
  open_writer ~base_path ~keeper_name
  |> Result.map (fun writer ->
    { operations = operations writer; end_cursor = end_cursor writer })
;;
let read_slice ~base_path ~keeper_name ~from =
  let path = journal_path ~base_path ~keeper_name in
  match
    Fs_compat.read_private_jsonl_slice_locked_result
      path
      ~from:(Cursor.to_int from)
  with
  | Error error -> Error (Read_failed error)
  | Ok source ->
    (match Record.decode_rows ~from ~row_number:None source.bytes with
     | Error error -> Error (Invalid_history (Invalid_record error))
     | Ok rows -> Ok { rows; end_cursor = cursor source.end_offset })
;;
let transaction_error_of_append = function
  | Fs_compat.End_offset_mismatch { expected; actual } ->
    Cursor_conflict { expected = cursor expected; actual = cursor actual }
  | Fs_compat.Durable_jsonl_append_failed
      ({ rollback_failures = []; _ } as error) ->
    Not_committed error
  | Fs_compat.Durable_jsonl_append_failed error -> Outcome_unknown error
  | ( Fs_compat.Incomplete_jsonl_tail
    | Fs_compat.Invalid_jsonl_suffix
    | Fs_compat.Negative_expected_end_offset _ ) as error ->
    Storage_rejected error
;;
let append writer ~recorded_at event =
  let journal_event = Event.Compaction event in
  match Record.encode ~recorded_at journal_event with
  | Error error -> Error (Encode_failed error)
  | Ok suffix ->
    let start_cursor = end_cursor writer in
    let end_cursor =
      cursor (Cursor.to_int start_cursor + String.length suffix)
    in
    let row =
      { Record.recorded_at
      ; start_cursor
      ; end_cursor
      ; event = journal_event
      }
    in
    (match Projection.apply writer.projection row with
     | Error error -> Error (Event_rejected error)
     | Ok projection ->
    (try
       match
         Fs_compat.append_private_jsonl_durable_locked_at_end_offset_result
           writer.path
           ~expected_end_offset:(Cursor.to_int start_cursor)
           suffix
       with
     | Ok committed_end_cursor ->
       if committed_end_cursor = Cursor.to_int end_cursor
       then Ok ({ writer with projection }, row)
       else
         Error
           (Transaction_error
              (Committed_cursor_mismatch
                 { expected = end_cursor
                 ; actual = cursor committed_end_cursor
                 }))
     | Error error ->
       Error (Transaction_error (transaction_error_of_append error))
     with
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | exn -> Error (Transaction_error (Access_failed exn))))
;;
