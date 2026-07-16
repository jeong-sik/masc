module Operation = Keeper_compaction_operation
module Reducer = Keeper_compaction_operation_reducer
module Event = Keeper_operation_event
module Record = Keeper_operation_record
module Cursor = Record.Cursor
type row = Record.row
type operation_entry =
  { snapshot : Reducer.snapshot
  ; requested_at : float
  ; request_cursor : Cursor.t
  }
type replay = { operations : operation_entry list; end_cursor : Cursor.t }
type slice = { rows : row list; end_cursor : Cursor.t }
type event_rejection =
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
  | Not_committed of Fs_compat.durable_append_error
  | Outcome_unknown of Fs_compat.durable_append_error
  | Access_failed of exn
type append_error =
  | Encode_failed of Record.envelope_error
  | Existing_history_invalid of history_error
  | Event_rejected of event_rejection
  | Transaction_error of transaction_error
module Operation_map = Map.Make (struct
    type t = Operation.Operation_id.t
    let compare = Operation.Operation_id.compare
  end)
type operation_state =
  { reducer : Reducer.state
  ; requested_at : float
  ; request_cursor : Cursor.t
  }
type fold_state =
  { operations : operation_state Operation_map.t
  ; producers : (Operation.producer_ref * Operation.Operation_id.t) list
  }
let empty_state = { operations = Operation_map.empty; producers = [] }
let ( let* ) = Result.bind
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
let producer_of_event event =
  match Operation.view event with
  | Operation.Requested { producer; _ } -> producer
  | _ -> None
;;
let find_producer producer =
  List.find_map (fun (candidate, operation_id) ->
    if Operation.producer_ref_equal producer candidate
    then Some operation_id
    else None)
;;
let apply_row ~keeper_name state row =
  let event =
    match row.Record.event with
    | Event.Compaction event -> event
  in
  let operation_id = Operation.operation_id event in
  let current = Operation_map.find_opt operation_id state.operations in
  let* next =
    Reducer.apply (Option.map (fun value -> value.reducer) current) event
    |> Result.map_error (fun error -> Transition_rejected error)
  in
  let actual = (Reducer.snapshot next).keeper_name in
  if not (Keeper_id.Keeper_name.equal keeper_name actual)
  then Error (Keeper_mismatch { expected = keeper_name; actual })
  else
    let operation =
      match current with
      | Some value -> { value with reducer = next }
      | None ->
        { reducer = next
        ; requested_at = row.recorded_at
        ; request_cursor = row.end_cursor
        }
    in
    match producer_of_event event with
    | Some producer ->
      (match find_producer producer state.producers with
       | Some existing_operation_id
         when not (Operation.Operation_id.equal existing_operation_id operation_id) ->
         Error (Producer_already_bound { producer; existing_operation_id })
       | Some _ ->
         Ok { state with operations = Operation_map.add operation_id operation state.operations }
       | None ->
         Ok
           { operations = Operation_map.add operation_id operation state.operations
           ; producers = (producer, operation_id) :: state.producers
           })
    | None ->
      Ok { state with operations = Operation_map.add operation_id operation state.operations }
;;
let fold_rows ~keeper_name rows =
  let rec loop row_number state = function
    | [] -> Ok state
    | row :: rest ->
      (match apply_row ~keeper_name state row with
       | Ok state -> loop (row_number + 1) state rest
       | Error rejection ->
         Error
           (Rejected_row
              { row_number
              ; start_cursor = row.start_cursor
              ; end_cursor = row.end_cursor
              ; rejection
              }))
  in
  loop 1 empty_state rows
;;
let decode_history ~keeper_name bytes =
  match Record.decode_rows ~from:Cursor.zero ~row_number:(Some 1) bytes with
  | Error error -> Error (Invalid_record error)
  | Ok rows ->
    fold_rows ~keeper_name rows |> Result.map (fun state -> rows, state)
;;
let replay ~base_path ~keeper_name =
  let path = journal_path ~base_path ~keeper_name in
  match Fs_compat.read_private_jsonl_slice_locked_result path ~from:0 with
  | Error error -> Error (Read_failed error)
  | Ok source ->
    (match decode_history ~keeper_name source.bytes with
     | Error error -> Error (Invalid_history error)
     | Ok (_, state) ->
       Ok
         { operations =
             Operation_map.bindings state.operations
             |> List.map (fun (_, value) ->
               { snapshot = Reducer.snapshot value.reducer
               ; requested_at = value.requested_at
               ; request_cursor = value.request_cursor
               })
             |> List.sort (fun (left : operation_entry) right ->
               Int.compare
                 (Cursor.to_int left.request_cursor)
                 (Cursor.to_int right.request_cursor))
         ; end_cursor = cursor source.end_offset
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
    (match Record.decode_rows ~from ~row_number:None source.bytes with
     | Error error -> Error (Invalid_history (Invalid_record error))
     | Ok rows -> Ok { rows; end_cursor = cursor source.end_offset })
;;
let append ~base_path ~keeper_name ~recorded_at event =
  let journal_event = Event.Compaction event in
  match Record.encode ~recorded_at journal_event with
  | Error error -> Error (Encode_failed error)
  | Ok suffix ->
    let path = journal_path ~base_path ~keeper_name in
    (try
       match
       Fs_compat.update_private_file_durable_locked_result path (fun existing ->
         match decode_history ~keeper_name existing with
         | Error error -> None, Error (Existing_history_invalid error)
         | Ok (_, state) ->
           let start_cursor = cursor (String.length existing) in
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
           (match apply_row ~keeper_name state row with
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
