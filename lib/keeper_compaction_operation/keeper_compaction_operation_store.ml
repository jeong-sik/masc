module Operation = Keeper_compaction_operation
module Reducer = Keeper_compaction_operation_reducer
module Codec = Keeper_compaction_operation_codec
module Record = Keeper_operation_record
module Cursor = Record.Cursor
module Projection = Keeper_compaction_operation_projection
type row = Operation.event Record.row
type operation_entry = Projection.operation_entry =
  { snapshot : Reducer.snapshot
  ; requested_at : float
  ; request_cursor : Cursor.t
  }
type replay = { operations : operation_entry list; end_cursor : Cursor.t }
type slice = { rows : row list; end_cursor : Cursor.t }
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
      { producer : Tool_invocation_ref.t
      ; existing_operation_id : Operation.Operation_id.t
      }
type history_error =
  | Invalid_record of Codec.decode_error Record.decode_error
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
  | Not_committed of Fs_compat.durable_append_error
  | Outcome_unknown of Fs_compat.durable_append_error
  | Access_failed of exn
type append_error =
  | Encode_failed of Record.encode_error
  | Existing_history_invalid of history_error
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
  match
    Record.decode_rows
      ~decode_event:Codec.of_json
      ~from:Cursor.zero
      ~row_number:(Some 1)
      bytes
  with
  | Error error -> Error (Invalid_record error)
  | Ok rows ->
    Projection.replay ~keeper_name rows
    |> Result.map_error (function
      | Projection.Rejected_row
          { row_number; start_cursor; end_cursor; rejection } ->
        Rejected_row { row_number; start_cursor; end_cursor; rejection })
;;
let replay ~base_path ~keeper_name =
  let path = journal_path ~base_path ~keeper_name in
  match Fs_compat.read_private_jsonl_slice_locked_result path ~from:0 with
  | Error error -> Error (Read_failed error)
  | Ok source ->
    (match decode_history ~keeper_name source.bytes with
     | Error error -> Error (Invalid_history error)
     | Ok state ->
       Ok
         { operations = Projection.operations state
         ; end_cursor = Projection.end_cursor state
         })
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
    (match
       Record.decode_rows
         ~decode_event:Codec.of_json
         ~from
         ~row_number:None
         source.bytes
     with
     | Error error -> Error (Invalid_history (Invalid_record error))
     | Ok rows -> Ok { rows; end_cursor = cursor source.end_offset })
;;
let append ~base_path ~keeper_name ~recorded_at event =
  match Record.encode ~encode_event:Codec.to_json ~recorded_at event with
  | Error error -> Error (Encode_failed error)
  | Ok suffix ->
    let path = journal_path ~base_path ~keeper_name in
    (try
       match
       Fs_compat.update_private_file_durable_locked_result path (fun existing ->
         match decode_history ~keeper_name existing with
         | Error error -> None, Error (Existing_history_invalid error)
         | Ok state ->
           let start_cursor = cursor (String.length existing) in
           let end_cursor =
             cursor (Cursor.to_int start_cursor + String.length suffix)
           in
           let row =
             { Record.recorded_at
             ; start_cursor
             ; end_cursor
             ; event
             }
           in
           (match Projection.apply state row with
            | Error error -> None, Error (Event_rejected error)
            | Ok _ -> Some suffix, Ok row))
     with
     | Ok result -> result
     | Error ({ rollback_failures = []; _ } as error) ->
       Error (Transaction_error (Not_committed error))
     | Error error -> Error (Transaction_error (Outcome_unknown error))
     with
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | exn -> Error (Transaction_error (Access_failed exn)))
;;
